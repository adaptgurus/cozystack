// SPDX-License-Identifier: Apache-2.0

package vmtemplate

import (
	"fmt"
	"sort"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

// SanitizeResult reports which native KubeVirt template objects were removed
// from the reusable VM definition. The template-owned source DataVolumes are
// intentionally not deleted here; they remain under the native template's
// ownership and are garbage-collected with that template.
type SanitizeResult struct {
	Changed             bool
	RemovedVolumes      []string
	RemovedDiskDevices  []string
	RemovedDataTemplates []string
}

// StripOpticalVolumes removes optical volumes from the VirtualMachine embedded
// in a KubeVirt VirtualMachineTemplate. KubeVirt's template capture clones the
// source VM's backed-up volumes before creating this object, so sanitizing the
// embedded VM/DVT definition prevents installer/VirtIO media from being cloned
// into every future VM while preserving the captured disk data until normal
// template deletion.
//
// The operation is idempotent. It fails closed on malformed template shape so a
// Convert transaction can never retire its source VM on an unverified template.
func StripOpticalVolumes(tpl *unstructured.Unstructured, excluded []string) (SanitizeResult, error) {
	result := SanitizeResult{}
	if tpl == nil {
		return result, fmt.Errorf("VirtualMachineTemplate is required")
	}
	if len(excluded) == 0 {
		return result, nil
	}

	excludedSet := make(map[string]struct{}, len(excluded))
	for _, name := range excluded {
		if name != "" {
			excludedSet[name] = struct{}{}
		}
	}
	if len(excludedSet) == 0 {
		return result, nil
	}

	vm, found, err := unstructured.NestedMap(tpl.Object, "spec", "virtualMachine")
	if err != nil {
		return result, fmt.Errorf("read template virtualMachine: %w", err)
	}
	if !found || vm == nil {
		return result, fmt.Errorf("VirtualMachineTemplate %s/%s has no spec.virtualMachine", tpl.GetNamespace(), tpl.GetName())
	}

	volumes, found, err := unstructured.NestedSlice(vm, "spec", "template", "spec", "volumes")
	if err != nil {
		return result, fmt.Errorf("read template VM volumes: %w", err)
	}
	if !found {
		return result, fmt.Errorf("VirtualMachineTemplate %s/%s embedded VM has no volumes", tpl.GetNamespace(), tpl.GetName())
	}

	// KubeVirt rewrites captured persistent volumes to DataVolumes and creates a
	// matching DataVolumeTemplate. Capture those generated names while removing
	// the volume, so the DVT can be removed as well.
	generatedDVTs := map[string]struct{}{}
	keptVolumes := make([]interface{}, 0, len(volumes))
	for _, raw := range volumes {
		volume, ok := raw.(map[string]interface{})
		if !ok {
			return result, fmt.Errorf("VirtualMachineTemplate %s/%s contains malformed VM volume", tpl.GetNamespace(), tpl.GetName())
		}
		name, _ := volume["name"].(string)
		if _, remove := excludedSet[name]; !remove {
			keptVolumes = append(keptVolumes, raw)
			continue
		}
		result.Changed = true
		result.RemovedVolumes = append(result.RemovedVolumes, name)
		if dv, ok := volume["dataVolume"].(map[string]interface{}); ok {
			if dvName, _ := dv["name"].(string); dvName != "" {
				generatedDVTs[dvName] = struct{}{}
			}
		}
	}
	if err := unstructured.SetNestedSlice(vm, keptVolumes, "spec", "template", "spec", "volumes"); err != nil {
		return result, fmt.Errorf("write sanitized template VM volumes: %w", err)
	}

	disks, found, err := unstructured.NestedSlice(vm, "spec", "template", "spec", "domain", "devices", "disks")
	if err != nil {
		return result, fmt.Errorf("read template VM disk devices: %w", err)
	}
	if found {
		keptDisks := make([]interface{}, 0, len(disks))
		for _, raw := range disks {
			disk, ok := raw.(map[string]interface{})
			if !ok {
				return result, fmt.Errorf("VirtualMachineTemplate %s/%s contains malformed VM disk device", tpl.GetNamespace(), tpl.GetName())
			}
			name, _ := disk["name"].(string)
			if _, remove := excludedSet[name]; !remove {
				keptDisks = append(keptDisks, raw)
				continue
			}
			result.Changed = true
			result.RemovedDiskDevices = append(result.RemovedDiskDevices, name)
		}
		if err := unstructured.SetNestedSlice(vm, keptDisks, "spec", "template", "spec", "domain", "devices", "disks"); err != nil {
			return result, fmt.Errorf("write sanitized template VM disk devices: %w", err)
		}
	}

	dvts, found, err := unstructured.NestedSlice(vm, "spec", "dataVolumeTemplates")
	if err != nil {
		return result, fmt.Errorf("read template VM dataVolumeTemplates: %w", err)
	}
	if found && len(generatedDVTs) > 0 {
		keptDVTs := make([]interface{}, 0, len(dvts))
		for _, raw := range dvts {
			dvt, ok := raw.(map[string]interface{})
			if !ok {
				return result, fmt.Errorf("VirtualMachineTemplate %s/%s contains malformed dataVolumeTemplate", tpl.GetNamespace(), tpl.GetName())
			}
			name, _, _ := unstructured.NestedString(dvt, "metadata", "name")
			if _, remove := generatedDVTs[name]; !remove {
				keptDVTs = append(keptDVTs, raw)
				continue
			}
			result.Changed = true
			result.RemovedDataTemplates = append(result.RemovedDataTemplates, name)
		}
		if err := unstructured.SetNestedSlice(vm, keptDVTs, "spec", "dataVolumeTemplates"); err != nil {
			return result, fmt.Errorf("write sanitized template VM dataVolumeTemplates: %w", err)
		}
	}

	if err := unstructured.SetNestedMap(tpl.Object, vm, "spec", "virtualMachine"); err != nil {
		return result, fmt.Errorf("write sanitized template virtualMachine: %w", err)
	}

	// Fail closed if any excluded runtime attachment remains after the rewrite.
	remainingVolumes, _, _ := unstructured.NestedSlice(vm, "spec", "template", "spec", "volumes")
	for _, raw := range remainingVolumes {
		if volume, ok := raw.(map[string]interface{}); ok {
			if name, _ := volume["name"].(string); name != "" {
				if _, forbidden := excludedSet[name]; forbidden {
					return SanitizeResult{}, fmt.Errorf("optical volume %q remained after template sanitation", name)
				}
			}
		}
	}

	sort.Strings(result.RemovedVolumes)
	sort.Strings(result.RemovedDiskDevices)
	sort.Strings(result.RemovedDataTemplates)
	return result, nil
}
