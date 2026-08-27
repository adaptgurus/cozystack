// SPDX-License-Identifier: Apache-2.0

package vmtemplate

import (
	"reflect"
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

func TestStripOpticalVolumesRemovesDeviceVolumeAndDVT(t *testing.T) {
	tpl := nativeTemplateFixture()
	result, err := StripOpticalVolumes(tpl, []string{"cdrom-installer", "cdrom-drivers"})
	if err != nil {
		t.Fatalf("StripOpticalVolumes: %v", err)
	}
	if !result.Changed {
		t.Fatal("expected sanitation to change template")
	}
	if !reflect.DeepEqual(result.RemovedVolumes, []string{"cdrom-drivers", "cdrom-installer"}) {
		t.Fatalf("removed volumes = %v", result.RemovedVolumes)
	}
	if !reflect.DeepEqual(result.RemovedDiskDevices, []string{"cdrom-drivers", "cdrom-installer"}) {
		t.Fatalf("removed disk devices = %v", result.RemovedDiskDevices)
	}
	if !reflect.DeepEqual(result.RemovedDataTemplates, []string{"drivers-${NAME}", "installer-${NAME}"}) {
		t.Fatalf("removed DVTs = %v", result.RemovedDataTemplates)
	}

	volumes, _, _ := unstructured.NestedSlice(tpl.Object, "spec", "virtualMachine", "spec", "template", "spec", "volumes")
	if len(volumes) != 1 || volumes[0].(map[string]interface{})["name"] != "disk-system" {
		t.Fatalf("remaining volumes = %#v, want only disk-system", volumes)
	}
	disks, _, _ := unstructured.NestedSlice(tpl.Object, "spec", "virtualMachine", "spec", "template", "spec", "domain", "devices", "disks")
	if len(disks) != 1 || disks[0].(map[string]interface{})["name"] != "disk-system" {
		t.Fatalf("remaining disk devices = %#v, want only disk-system", disks)
	}
	dvts, _, _ := unstructured.NestedSlice(tpl.Object, "spec", "virtualMachine", "spec", "dataVolumeTemplates")
	if len(dvts) != 1 {
		t.Fatalf("remaining DVTs = %#v, want one", dvts)
	}
	name, _, _ := unstructured.NestedString(dvts[0].(map[string]interface{}), "metadata", "name")
	if name != "system-${NAME}" {
		t.Fatalf("remaining DVT = %q, want system-${NAME}", name)
	}
}

func TestStripOpticalVolumesIsIdempotent(t *testing.T) {
	tpl := nativeTemplateFixture()
	if _, err := StripOpticalVolumes(tpl, []string{"cdrom-installer"}); err != nil {
		t.Fatalf("first sanitation: %v", err)
	}
	result, err := StripOpticalVolumes(tpl, []string{"cdrom-installer"})
	if err != nil {
		t.Fatalf("second sanitation: %v", err)
	}
	if result.Changed {
		t.Fatalf("second sanitation changed already sanitized template: %#v", result)
	}
}

func TestStripOpticalVolumesFailsClosedOnMalformedTemplate(t *testing.T) {
	tpl := &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "template.kubevirt.io/v1alpha1",
		"kind":       "VirtualMachineTemplate",
		"metadata":   map[string]interface{}{"name": "broken", "namespace": "tenant-a"},
	}}
	if _, err := StripOpticalVolumes(tpl, []string{"cdrom-installer"}); err == nil {
		t.Fatal("expected malformed native template to be rejected")
	}
}

func nativeTemplateFixture() *unstructured.Unstructured {
	return &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "template.kubevirt.io/v1alpha1",
		"kind":       "VirtualMachineTemplate",
		"metadata": map[string]interface{}{
			"name":      "golden",
			"namespace": "tenant-a",
		},
		"spec": map[string]interface{}{
			"virtualMachine": map[string]interface{}{
				"spec": map[string]interface{}{
					"dataVolumeTemplates": []interface{}{
						map[string]interface{}{"metadata": map[string]interface{}{"name": "system-${NAME}"}},
						map[string]interface{}{"metadata": map[string]interface{}{"name": "installer-${NAME}"}},
						map[string]interface{}{"metadata": map[string]interface{}{"name": "drivers-${NAME}"}},
					},
					"template": map[string]interface{}{
						"spec": map[string]interface{}{
							"domain": map[string]interface{}{
								"devices": map[string]interface{}{
									"disks": []interface{}{
										map[string]interface{}{"name": "disk-system", "disk": map[string]interface{}{}},
										map[string]interface{}{"name": "cdrom-installer", "cdrom": map[string]interface{}{"bus": "sata"}},
										map[string]interface{}{"name": "cdrom-drivers", "cdrom": map[string]interface{}{"bus": "sata"}},
									},
								},
							},
							"volumes": []interface{}{
								map[string]interface{}{"name": "disk-system", "dataVolume": map[string]interface{}{"name": "system-${NAME}"}},
								map[string]interface{}{"name": "cdrom-installer", "dataVolume": map[string]interface{}{"name": "installer-${NAME}"}},
								map[string]interface{}{"name": "cdrom-drivers", "dataVolume": map[string]interface{}{"name": "drivers-${NAME}"}},
							},
						},
					},
				},
			},
		},
	}}
}
