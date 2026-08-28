// SPDX-License-Identifier: Apache-2.0

package vmtemplate

import (
	"fmt"
	"sort"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

// BootstrapSanitizeResult reports one-time initialization material removed
// from a reusable VM template. Cloud-init, ConfigDrive and Sysprep data are
// source-instance bootstrap inputs, not reusable machine identity. KubeVirt
// accessCredentials commonly reference the source VMInstance's SSH Secret and
// are also removed so Convert cannot leave a template pointing at a Secret
// that disappears with the source Helm release.
type BootstrapSanitizeResult struct {
	Changed                  bool
	RemovedVolumes           []string
	RemovedDiskDevices       []string
	RemovedAccessCredentials int
}

// StripOneTimeBootstrap removes source-instance bootstrap material from the VM
// embedded in a native KubeVirt VirtualMachineTemplate. The function is
// idempotent and fails closed on malformed volume/device shapes.
func StripOneTimeBootstrap(tpl *unstructured.Unstructured) (BootstrapSanitizeResult, error) {
	result := BootstrapSanitizeResult{}
	if tpl == nil {
		return result, fmt.Errorf("VirtualMachineTemplate is required")
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

	removed := map[string]struct{}{}
	keptVolumes := make([]interface{}, 0, len(volumes))
	for _, raw := range volumes {
		volume, ok := raw.(map[string]interface{})
		if !ok {
			return result, fmt.Errorf("VirtualMachineTemplate %s/%s contains malformed VM volume", tpl.GetNamespace(), tpl.GetName())
		}
		name, _ := volume["name"].(string)
		if name == "" {
			return result, fmt.Errorf("VirtualMachineTemplate %s/%s contains VM volume without a name", tpl.GetNamespace(), tpl.GetName())
		}
		oneTime := false
		for _, key := range []string{"cloudInitNoCloud", "cloudInitConfigDrive", "sysprep"} {
			if _, ok := volume[key]; ok {
				oneTime = true
				break
			}
		}
		if !oneTime {
			keptVolumes = append(keptVolumes, raw)
			continue
		}
		removed[name] = struct{}{}
		result.Changed = true
		result.RemovedVolumes = append(result.RemovedVolumes, name)
	}
	if err := unstructured.SetNestedSlice(vm, keptVolumes, "spec", "template", "spec", "volumes"); err != nil {
		return result, fmt.Errorf("write template VM volumes after bootstrap sanitation: %w", err)
	}

	if len(removed) > 0 {
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
				if _, drop := removed[name]; !drop {
					keptDisks = append(keptDisks, raw)
					continue
				}
				result.Changed = true
				result.RemovedDiskDevices = append(result.RemovedDiskDevices, name)
			}
			if err := unstructured.SetNestedSlice(vm, keptDisks, "spec", "template", "spec", "domain", "devices", "disks"); err != nil {
				return result, fmt.Errorf("write template VM disk devices after bootstrap sanitation: %w", err)
			}
		}
	}

	accessCredentials, found, err := unstructured.NestedSlice(vm, "spec", "template", "spec", "accessCredentials")
	if err != nil {
		return result, fmt.Errorf("read template VM accessCredentials: %w", err)
	}
	if found && len(accessCredentials) > 0 {
		result.Changed = true
		result.RemovedAccessCredentials = len(accessCredentials)
		unstructured.RemoveNestedField(vm, "spec", "template", "spec", "accessCredentials")
	}

	if err := unstructured.SetNestedMap(tpl.Object, vm, "spec", "virtualMachine"); err != nil {
		return result, fmt.Errorf("write sanitized template virtualMachine: %w", err)
	}

	remainingVolumes, _, _ := unstructured.NestedSlice(vm, "spec", "template", "spec", "volumes")
	for _, raw := range remainingVolumes {
		volume, ok := raw.(map[string]interface{})
		if !ok {
			return BootstrapSanitizeResult{}, fmt.Errorf("VirtualMachineTemplate %s/%s contains malformed VM volume after sanitation", tpl.GetNamespace(), tpl.GetName())
		}
		for _, key := range []string{"cloudInitNoCloud", "cloudInitConfigDrive", "sysprep"} {
			if _, present := volume[key]; present {
				name, _ := volume["name"].(string)
				return BootstrapSanitizeResult{}, fmt.Errorf("one-time bootstrap volume %q remained after template sanitation", name)
			}
		}
	}
	if credentials, present, _ := unstructured.NestedSlice(vm, "spec", "template", "spec", "accessCredentials"); present && len(credentials) > 0 {
		return BootstrapSanitizeResult{}, fmt.Errorf("accessCredentials remained after template sanitation")
	}

	sort.Strings(result.RemovedVolumes)
	sort.Strings(result.RemovedDiskDevices)
	return result, nil
}
