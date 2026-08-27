// SPDX-License-Identifier: Apache-2.0

package vmtemplate

import (
	"context"
	"strings"
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	dynamicfake "k8s.io/client-go/dynamic/fake"
)

func TestDiscoverCapabilitiesRequiresAllNativeTemplateControls(t *testing.T) {
	client := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), kubeVirtObject(true, true, true))
	caps, err := (&KubeVirtTemplateBackend{Client: client}).DiscoverCapabilities(context.Background())
	if err != nil {
		t.Fatalf("DiscoverCapabilities: %v", err)
	}
	if !caps.NativeTemplatesReady() {
		t.Fatalf("capabilities = %+v, expected native templates ready", caps)
	}
	if got := strings.Join(FeatureGateNames(caps), ","); got != "Snapshot,Template,virtTemplateDeployment" {
		t.Fatalf("feature names = %q", got)
	}
}

func TestCreateTemplateIsIdempotentOnlyForSameImmutableIntent(t *testing.T) {
	ctx := context.Background()
	client := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), kubeVirtObject(true, true, true))
	backend := &KubeVirtTemplateBackend{Client: client}
	req := CreateRequest{Namespace: "tenant-test", RequestName: "vm-template-gold-capture", TemplateName: "vm-template-gold-native", SourceVMName: "vm-instance-source"}
	state, err := backend.CreateTemplate(ctx, req)
	if err != nil {
		t.Fatalf("CreateTemplate: %v", err)
	}
	if state.RequestName != req.RequestName || state.Ready {
		t.Fatalf("initial state = %+v", state)
	}
	if _, err := backend.CreateTemplate(ctx, req); err != nil {
		t.Fatalf("idempotent CreateTemplate: %v", err)
	}
	conflict := req
	conflict.SourceVMName = "vm-instance-other"
	if _, err := backend.CreateTemplate(ctx, conflict); err == nil || !strings.Contains(err.Error(), "different immutable") {
		t.Fatalf("expected immutable request collision, got %v", err)
	}
}

func TestVerifyTemplateRequiresRequestAndTemplateReady(t *testing.T) {
	ctx := context.Background()
	request := &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "template.kubevirt.io/v1alpha1",
		"kind":       "VirtualMachineTemplateRequest",
		"metadata": map[string]interface{}{"name": "capture", "namespace": "tenant-test"},
		"spec": map[string]interface{}{
			"virtualMachineRef": map[string]interface{}{"namespace": "tenant-test", "name": "vm-instance-source"},
			"templateName": "native-template",
		},
		"status": map[string]interface{}{
			"conditions": []interface{}{map[string]interface{}{"type": "Ready", "status": "True"}},
			"templateRef": map[string]interface{}{"name": "native-template"},
		},
	}}
	template := &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "template.kubevirt.io/v1alpha1",
		"kind":       "VirtualMachineTemplate",
		"metadata": map[string]interface{}{"name": "native-template", "namespace": "tenant-test"},
		"spec": map[string]interface{}{"virtualMachine": map[string]interface{}{}},
		"status": map[string]interface{}{"conditions": []interface{}{map[string]interface{}{"type": "Ready", "status": "True"}}},
	}}
	client := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), request, template)
	state, err := (&KubeVirtTemplateBackend{Client: client}).VerifyTemplate(ctx, TemplateRef{Namespace: "tenant-test", Name: "native-template"}, "capture")
	if err != nil {
		t.Fatalf("VerifyTemplate: %v", err)
	}
	if !state.Ready || state.TemplateName != "native-template" {
		t.Fatalf("state = %+v", state)
	}
}

func TestValidateSourceUsesLiveVMIState(t *testing.T) {
	ctx := context.Background()
	vm := testVM("Halted", []interface{}{map[string]interface{}{"name": "root", "dataVolume": map[string]interface{}{"name": "vm-disk-root"}}}, nil)
	vmi := &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "kubevirt.io/v1",
		"kind":       "VirtualMachineInstance",
		"metadata": map[string]interface{}{"name": vm.GetName(), "namespace": vm.GetNamespace()},
	}}
	client := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), vm, vmi)
	_, err := (&KubeVirtTemplateBackend{Client: client}).ValidateSource(ctx, TemplateRef{Namespace: vm.GetNamespace(), Name: vm.GetName()}, SourcePolicy{RequireHalted: true})
	if err == nil || !strings.Contains(err.Error(), "active VMI") {
		t.Fatalf("expected live VMI rejection, got %v", err)
	}
}

func kubeVirtObject(snapshot, template, deployment bool) *unstructured.Unstructured {
	gates := []interface{}{}
	if snapshot {
		gates = append(gates, "Snapshot")
	}
	if template {
		gates = append(gates, "Template")
	}
	return &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "kubevirt.io/v1",
		"kind":       "KubeVirt",
		"metadata": map[string]interface{}{"name": "kubevirt", "namespace": kubeVirtNamespace},
		"spec": map[string]interface{}{
			"configuration": map[string]interface{}{
				"developerConfiguration": map[string]interface{}{"featureGates": gates},
				"virtTemplateDeployment": map[string]interface{}{"enabled": deployment},
			},
		},
	}}
}
