// SPDX-License-Identifier: Apache-2.0

// Package vmtemplate contains the Cozystack product boundary for VM template
// creation. It deliberately keeps the alpha KubeVirt template API behind a
// narrow adapter and performs fail-closed source validation before storage is
// snapshotted or a source VM can be converted.
package vmtemplate

import (
	"fmt"
	"sort"
	"strings"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

// SourcePolicy controls safety checks for creating a reusable VM template.
type SourcePolicy struct {
	// RequireHalted requires runStrategy=Halted in addition to no active VMI.
	// This prevents an Always/RerunOnFailure VM from racing the snapshot after
	// the preflight observes it stopped.
	RequireHalted bool
	// ExcludeOpticalMedia excludes CD/DVD-backed volumes from the reusable
	// template capture. Installer and driver media should not become writable
	// template disks or be required for every clone.
	ExcludeOpticalMedia bool
	// AllowSecretReferences is appropriate for tenant-local templates when the
	// referenced Secret remains in the same authoritative tenant namespace.
	// Global promotion must set this false and parameterize/remove secrets first.
	AllowSecretReferences bool
}

// SourceSummary is the storage/security inventory proven by ValidateSource.
type SourceSummary struct {
	PersistentVolumes     []string
	OpticalVolumes        []string
	SecretReferenceVolumes []string
}

// ValidateSource proves that a KubeVirt VirtualMachine is safe to hand to the
// template backend. vmiExists must be obtained from the live VMI API; callers
// must not infer running state from the VM spec alone.
func ValidateSource(vm *unstructured.Unstructured, vmiExists bool, policy SourcePolicy) (SourceSummary, error) {
	if vm == nil {
		return SourceSummary{}, fmt.Errorf("source VirtualMachine is required")
	}
	if vm.GetNamespace() == "" || vm.GetName() == "" {
		return SourceSummary{}, fmt.Errorf("source VirtualMachine must have namespace and name")
	}
	if vmiExists {
		return SourceSummary{}, fmt.Errorf("source VirtualMachine %s/%s still has an active VMI; stop it before creating a template", vm.GetNamespace(), vm.GetName())
	}
	if policy.RequireHalted {
		runStrategy, _, err := unstructured.NestedString(vm.Object, "spec", "runStrategy")
		if err != nil {
			return SourceSummary{}, fmt.Errorf("read source VM runStrategy: %w", err)
		}
		if runStrategy != "Halted" {
			return SourceSummary{}, fmt.Errorf("source VirtualMachine %s/%s must use runStrategy=Halted during template capture, got %q", vm.GetNamespace(), vm.GetName(), runStrategy)
		}
	}

	optical, err := opticalVolumeNames(vm)
	if err != nil {
		return SourceSummary{}, err
	}
	volumes, found, err := unstructured.NestedSlice(vm.Object, "spec", "template", "spec", "volumes")
	if err != nil {
		return SourceSummary{}, fmt.Errorf("read source VM volumes: %w", err)
	}
	if !found {
		return SourceSummary{}, fmt.Errorf("source VirtualMachine %s/%s has no volumes", vm.GetNamespace(), vm.GetName())
	}

	summary := SourceSummary{}
	seenStorage := map[string]string{}
	for _, raw := range volumes {
		volume, ok := raw.(map[string]interface{})
		if !ok {
			return SourceSummary{}, fmt.Errorf("source VirtualMachine contains a malformed volume")
		}
		name, _ := volume["name"].(string)
		if name == "" {
			return SourceSummary{}, fmt.Errorf("source VirtualMachine contains a volume without a name")
		}
		if _, isOptical := optical[name]; isOptical {
			summary.OpticalVolumes = append(summary.OpticalVolumes, name)
			if policy.ExcludeOpticalMedia {
				continue
			}
		}

		storageKey, persistent, secretRef, unsupported := classifyVolume(volume)
		if unsupported != "" {
			return SourceSummary{}, fmt.Errorf("volume %q uses unsupported template source %s; only DataVolume/PVC-backed writable disks are supported", name, unsupported)
		}
		if secretRef {
			summary.SecretReferenceVolumes = append(summary.SecretReferenceVolumes, name)
			if !policy.AllowSecretReferences {
				return SourceSummary{}, fmt.Errorf("volume %q references secret-bearing configuration; parameterize or remove secrets before global template promotion", name)
			}
		}
		if !persistent {
			continue
		}
		if previous, duplicate := seenStorage[storageKey]; duplicate {
			return SourceSummary{}, fmt.Errorf("volumes %q and %q reference the same writable storage %q; refusing ambiguous template capture", previous, name, storageKey)
		}
		seenStorage[storageKey] = name
		summary.PersistentVolumes = append(summary.PersistentVolumes, name)
	}

	if len(summary.PersistentVolumes) == 0 {
		return SourceSummary{}, fmt.Errorf("source VirtualMachine %s/%s has no snapshot/clone-capable persistent disk after exclusions", vm.GetNamespace(), vm.GetName())
	}
	sort.Strings(summary.PersistentVolumes)
	sort.Strings(summary.OpticalVolumes)
	sort.Strings(summary.SecretReferenceVolumes)
	return summary, nil
}

func opticalVolumeNames(vm *unstructured.Unstructured) (map[string]struct{}, error) {
	out := map[string]struct{}{}
	disks, found, err := unstructured.NestedSlice(vm.Object, "spec", "template", "spec", "domain", "devices", "disks")
	if err != nil {
		return nil, fmt.Errorf("read source VM disks: %w", err)
	}
	if !found {
		return out, nil
	}
	for _, raw := range disks {
		disk, ok := raw.(map[string]interface{})
		if !ok {
			return nil, fmt.Errorf("source VirtualMachine contains a malformed disk device")
		}
		name, _ := disk["name"].(string)
		if name == "" {
			continue
		}
		if _, ok := disk["cdrom"]; ok {
			out[name] = struct{}{}
		}
	}
	return out, nil
}

// classifyVolume returns a stable storage identity, whether the volume is a
// persistent writable disk, whether it contains/references secret data, and an
// unsupported source name. Config-only volumes are allowed but not counted as
// persistent template disks.
func classifyVolume(volume map[string]interface{}) (string, bool, bool, string) {
	name, _ := volume["name"].(string)
	if dv, ok := volume["dataVolume"].(map[string]interface{}); ok {
		ref, _ := dv["name"].(string)
		if ref == "" {
			return "", false, false, "dataVolume-without-name"
		}
		return "dv:" + ref, true, false, ""
	}
	if pvc, ok := volume["persistentVolumeClaim"].(map[string]interface{}); ok {
		ref, _ := pvc["claimName"].(string)
		if ref == "" {
			return "", false, false, "persistentVolumeClaim-without-claimName"
		}
		return "pvc:" + ref, true, false, ""
	}

	// These volumes contain configuration, not a reusable writable VM disk.
	for _, key := range []string{"cloudInitNoCloud", "cloudInitConfigDrive", "secret", "sysprep"} {
		if _, ok := volume[key]; ok {
			return "config:" + name, false, true, ""
		}
	}
	for _, key := range []string{"configMap", "serviceAccount", "downwardAPI"} {
		if _, ok := volume[key]; ok {
			return "config:" + name, false, false, ""
		}
	}

	// Local/ephemeral media cannot provide an independently recoverable template
	// disk and would violate the no-shared-writable-storage invariant.
	for _, key := range []string{"hostDisk", "containerDisk", "emptyDisk", "ephemeral", "memoryDump"} {
		if _, ok := volume[key]; ok {
			return "", false, false, key
		}
	}
	keys := make([]string, 0, len(volume))
	for key := range volume {
		if key != "name" {
			keys = append(keys, key)
		}
	}
	sort.Strings(keys)
	if len(keys) == 0 {
		return "", false, false, "unknown-empty-volume"
	}
	return "", false, false, strings.Join(keys, ",")
}
