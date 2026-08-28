// SPDX-License-Identifier: Apache-2.0

package vmtemplate

import (
	"reflect"
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

func TestStripOneTimeBootstrapRemovesCloudInitSysprepAndAccessCredentials(t *testing.T) {
	tpl := bootstrapTemplateFixture()
	result, err := StripOneTimeBootstrap(tpl)
	if err != nil {
		t.Fatalf("StripOneTimeBootstrap: %v", err)
	}
	if !result.Changed {
		t.Fatal("expected bootstrap sanitation to change template")
	}
	if !reflect.DeepEqual(result.RemovedVolumes, []string{"cloudinitdisk", "sysprepdisk"}) {
		t.Fatalf("removed volumes = %v", result.RemovedVolumes)
	}
	if !reflect.DeepEqual(result.RemovedDiskDevices, []string{"cloudinitdisk", "sysprepdisk"}) {
		t.Fatalf("removed disk devices = %v", result.RemovedDiskDevices)
	}
	if result.RemovedAccessCredentials != 1 {
		t.Fatalf("removed access credentials = %d, want 1", result.RemovedAccessCredentials)
	}

	volumes, _, _ := unstructured.NestedSlice(tpl.Object, "spec", "virtualMachine", "spec", "template", "spec", "volumes")
	if len(volumes) != 1 || volumes[0].(map[string]interface{})["name"] != "disk-system" {
		t.Fatalf("remaining volumes = %#v, want only disk-system", volumes)
	}
	disks, _, _ := unstructured.NestedSlice(tpl.Object, "spec", "virtualMachine", "spec", "template", "spec", "domain", "devices", "disks")
	if len(disks) != 1 || disks[0].(map[string]interface{})["name"] != "disk-system" {
		t.Fatalf("remaining disk devices = %#v, want only disk-system", disks)
	}
	if credentials, found, _ := unstructured.NestedSlice(tpl.Object, "spec", "virtualMachine", "spec", "template", "spec", "accessCredentials"); found || len(credentials) != 0 {
		t.Fatalf("accessCredentials remain after sanitation: %#v", credentials)
	}
}

func TestStripOneTimeBootstrapPreservesTenantApplicationSecretVolume(t *testing.T) {
	tpl := bootstrapTemplateFixture()
	volumes, _, _ := unstructured.NestedSlice(tpl.Object, "spec", "virtualMachine", "spec", "template", "spec", "volumes")
	volumes = append(volumes, map[string]interface{}{"name": "app-secret", "secret": map[string]interface{}{"secretName": "app-secret"}})
	if err := unstructured.SetNestedSlice(tpl.Object, volumes, "spec", "virtualMachine", "spec", "template", "spec", "volumes"); err != nil {
		t.Fatalf("add application secret fixture: %v", err)
	}
	if _, err := StripOneTimeBootstrap(tpl); err != nil {
		t.Fatalf("StripOneTimeBootstrap: %v", err)
	}
	remaining, _, _ := unstructured.NestedSlice(tpl.Object, "spec", "virtualMachine", "spec", "template", "spec", "volumes")
	found := false
	for _, raw := range remaining {
		volume := raw.(map[string]interface{})
		if volume["name"] == "app-secret" {
			found = true
		}
	}
	if !found {
		t.Fatal("tenant application Secret volume should remain governed by the template secret-reference policy")
	}
}

func TestStripOneTimeBootstrapIsIdempotent(t *testing.T) {
	tpl := bootstrapTemplateFixture()
	if _, err := StripOneTimeBootstrap(tpl); err != nil {
		t.Fatalf("first sanitation: %v", err)
	}
	result, err := StripOneTimeBootstrap(tpl)
	if err != nil {
		t.Fatalf("second sanitation: %v", err)
	}
	if result.Changed {
		t.Fatalf("second sanitation changed already sanitized template: %#v", result)
	}
}

func bootstrapTemplateFixture() *unstructured.Unstructured {
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
					"template": map[string]interface{}{
						"spec": map[string]interface{}{
							"accessCredentials": []interface{}{
								map[string]interface{}{"sshPublicKey": map[string]interface{}{"source": map[string]interface{}{"secret": map[string]interface{}{"secretName": "source-ssh"}}}},
							},
							"domain": map[string]interface{}{
								"devices": map[string]interface{}{
									"disks": []interface{}{
										map[string]interface{}{"name": "disk-system", "disk": map[string]interface{}{}},
										map[string]interface{}{"name": "cloudinitdisk", "disk": map[string]interface{}{}},
										map[string]interface{}{"name": "sysprepdisk", "disk": map[string]interface{}{}},
									},
								},
							},
							"volumes": []interface{}{
								map[string]interface{}{"name": "disk-system", "dataVolume": map[string]interface{}{"name": "system-${NAME}"}},
								map[string]interface{}{"name": "cloudinitdisk", "cloudInitNoCloud": map[string]interface{}{"secretRef": map[string]interface{}{"name": "source-cloud-init"}}},
								map[string]interface{}{"name": "sysprepdisk", "sysprep": map[string]interface{}{"secret": map[string]interface{}{"name": "source-sysprep"}}},
							},
						},
					},
				},
			},
		},
	}}
}
