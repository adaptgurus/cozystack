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

func TestSanitizingBackendBlocksReadyUntilOpticalMediaIsPersistentlyRemoved(t *testing.T) {
	ctx := context.Background()
	tpl := capturedTemplateWithOptical()
	c := fake.NewClientBuilder().WithScheme(runtime.NewScheme()).WithObjects(tpl).Build()
	native := &fakeBackend{state: vmtemplate.TemplateState{RequestName: "gold", TemplateName: "gold", Ready: true}}
	backend := &SanitizingBackend{Backend: native, Client: c}
	ref := vmtemplate.TemplateRef{Namespace: "tenant-a", Name: "gold"}

	first, err := backend.VerifyTemplate(ctx, ref, "gold")
	if err != nil {
		t.Fatalf("first VerifyTemplate: %v", err)
	}
	if first.Ready {
		t.Fatal("first Ready verification must be blocked until optical sanitation is persisted")
	}

	current := &unstructured.Unstructured{}
	current.SetGroupVersionKind(nativeTemplateGVK)
	if err := c.Get(ctx, client.ObjectKey{Namespace: "tenant-a", Name: "gold"}, current); err != nil {
		t.Fatalf("get sanitized template: %v", err)
	}
	optical, err := vmtemplate.TemplateOpticalVolumes(current)
	if err != nil {
		t.Fatalf("inspect sanitized template: %v", err)
	}
	if len(optical) != 0 {
		t.Fatalf("optical media remains after persisted sanitation: %v", optical)
	}
	if current.GetAnnotations()[opticalSanitizedAnnotation] != "true" {
		t.Fatalf("sanitation annotation missing: %#v", current.GetAnnotations())
	}

	second, err := backend.VerifyTemplate(ctx, ref, "gold")
	if err != nil {
		t.Fatalf("second VerifyTemplate: %v", err)
	}
	if !second.Ready {
		t.Fatal("sanitized template should be Ready on the subsequent verification")
	}
}

func capturedTemplateWithOptical() *unstructured.Unstructured {
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
						map[string]interface{}{"metadata": map[string]interface{}{"name": "installer-${NAME}"}},
					},
					"template": map[string]interface{}{
						"spec": map[string]interface{}{
							"domain": map[string]interface{}{"devices": map[string]interface{}{"disks": []interface{}{
								map[string]interface{}{"name": "root", "disk": map[string]interface{}{}},
								map[string]interface{}{"name": "installer", "cdrom": map[string]interface{}{"bus": "sata"}},
							}}},
							"volumes": []interface{}{
								map[string]interface{}{"name": "root", "dataVolume": map[string]interface{}{"name": "root-${NAME}"}},
								map[string]interface{}{"name": "installer", "dataVolume": map[string]interface{}{"name": "installer-${NAME}"}},
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
