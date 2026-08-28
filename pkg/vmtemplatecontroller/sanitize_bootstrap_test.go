// SPDX-License-Identifier: Apache-2.0

package vmtemplatecontroller

import (
	"context"
	"testing"

	"github.com/cozystack/cozystack/pkg/vmtemplate"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func TestSanitizingBackendBlocksReadyUntilBootstrapMaterialIsPersistentlyRemoved(t *testing.T) {
	ctx := context.Background()
	tpl := capturedTemplateWithBootstrap()
	c := fake.NewClientBuilder().WithScheme(runtime.NewScheme()).WithObjects(tpl).Build()
	native := &fakeBackend{state: vmtemplate.TemplateState{RequestName: "gold", TemplateName: "gold", Ready: true}}
	backend := &SanitizingBackend{Backend: native, Client: c}
	ref := vmtemplate.TemplateRef{Namespace: "tenant-a", Name: "gold"}

	first, err := backend.VerifyTemplate(ctx, ref, "gold")
	if err != nil {
		t.Fatalf("first VerifyTemplate: %v", err)
	}
	if first.Ready {
		t.Fatal("first Ready verification must be blocked until bootstrap sanitation is persisted")
	}

	current := &unstructured.Unstructured{}
	current.SetGroupVersionKind(nativeTemplateGVK)
	if err := c.Get(ctx, client.ObjectKey{Namespace: "tenant-a", Name: "gold"}, current); err != nil {
		t.Fatalf("get sanitized template: %v", err)
	}
	volumes, _, _ := unstructured.NestedSlice(current.Object, "spec", "virtualMachine", "spec", "template", "spec", "volumes")
	if len(volumes) != 1 || volumes[0].(map[string]interface{})["name"] != "root" {
		t.Fatalf("bootstrap volumes remain after sanitation: %#v", volumes)
	}
	if credentials, found, _ := unstructured.NestedSlice(current.Object, "spec", "virtualMachine", "spec", "template", "spec", "accessCredentials"); found || len(credentials) != 0 {
		t.Fatalf("accessCredentials remain after sanitation: %#v", credentials)
	}
	if current.GetAnnotations()[bootstrapSanitizedAnnotation] != "true" {
		t.Fatalf("bootstrap sanitation annotation missing: %#v", current.GetAnnotations())
	}

	second, err := backend.VerifyTemplate(ctx, ref, "gold")
	if err != nil {
		t.Fatalf("second VerifyTemplate: %v", err)
	}
	if !second.Ready {
		t.Fatal("bootstrap-sanitized template should be Ready on the subsequent verification")
	}
}

func capturedTemplateWithBootstrap() *unstructured.Unstructured {
	tpl := &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "template.kubevirt.io/v1alpha1",
		"kind":       "VirtualMachineTemplate",
		"metadata": map[string]interface{}{
			"name":      "gold",
			"namespace": "tenant-a",
		},
		"spec": map[string]interface{}{
			"virtualMachine": map[string]interface{}{
				"spec": map[string]interface{}{
					"dataVolumeTemplates": []interface{}{
						map[string]interface{}{"metadata": map[string]interface{}{"name": "root-${NAME}"}},
					},
					"template": map[string]interface{}{
						"spec": map[string]interface{}{
							"accessCredentials": []interface{}{
								map[string]interface{}{"sshPublicKey": map[string]interface{}{"source": map[string]interface{}{"secret": map[string]interface{}{"secretName": "source-ssh"}}}},
							},
							"domain": map[string]interface{}{"devices": map[string]interface{}{"disks": []interface{}{
								map[string]interface{}{"name": "root", "disk": map[string]interface{}{}},
								map[string]interface{}{"name": "cloudinitdisk", "disk": map[string]interface{}{}},
							}}},
							"volumes": []interface{}{
								map[string]interface{}{"name": "root", "dataVolume": map[string]interface{}{"name": "root-${NAME}"}},
								map[string]interface{}{"name": "cloudinitdisk", "cloudInitNoCloud": map[string]interface{}{"secretRef": map[string]interface{}{"name": "source-cloud-init"}}},
							},
						},
					},
				},
			},
		},
	}}
	tpl.SetGroupVersionKind(nativeTemplateGVK)
	return tpl
}
