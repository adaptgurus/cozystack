// SPDX-License-Identifier: Apache-2.0

package vmtemplatecontroller

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/cozystack/cozystack/pkg/vmtemplate"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

type fakeBackend struct {
	state       vmtemplate.TemplateState
	summary     vmtemplate.SourceSummary
	validateErr error
	createErr   error
	deleteErr   error
	created     int
	deleted     int
}

func (f *fakeBackend) DiscoverCapabilities(context.Context) (vmtemplate.Capabilities, error) {
	return vmtemplate.Capabilities{SnapshotGate: true, TemplateGate: true, TemplateDeployment: true}, nil
}
func (f *fakeBackend) ValidateSource(context.Context, vmtemplate.TemplateRef, vmtemplate.SourcePolicy) (vmtemplate.SourceSummary, error) {
	return f.summary, f.validateErr
}
func (f *fakeBackend) CreateTemplate(_ context.Context, req vmtemplate.CreateRequest) (vmtemplate.TemplateState, error) {
	f.created++
	if f.createErr != nil {
		return vmtemplate.TemplateState{}, f.createErr
	}
	if f.state.RequestName == "" {
		f.state = vmtemplate.TemplateState{RequestName: req.RequestName, TemplateName: "", Ready: false}
	}
	return f.state, nil
}
func (f *fakeBackend) VerifyTemplate(context.Context, vmtemplate.TemplateRef, string) (vmtemplate.TemplateState, error) {
	return f.state, nil
}
func (f *fakeBackend) DeleteTemplate(context.Context, vmtemplate.TemplateRef, string) error {
	f.deleted++
	return f.deleteErr
}

func TestTemplateCopyPersistsCheckpointAndNeverDeletesSource(t *testing.T) {
	ctx := context.Background()
	op := operationObject("Copy")
	source := sourceVMInstance("source", "uid-source", 3)
	kvVM := kubeVirtVM("source")
	c := fakeClient(t, op, source, kvVM)
	backend := &fakeBackend{summary: vmtemplate.SourceSummary{PersistentVolumes: []string{"root"}, OpticalVolumes: []string{"installer"}}}
	r := &Reconciler{Client: c, Backend: backend, RequeueAfter: time.Millisecond}

	if _, err := r.Reconcile(ctx, ctrl.Request{NamespacedName: client.ObjectKeyFromObject(op)}); err != nil {
		t.Fatalf("initial reconcile: %v", err)
	}
	current := getOperation(t, ctx, c, op.GetNamespace(), op.GetName())
	if phase, _, _ := unstructured.NestedString(current.Object, "status", "phase"); phase != "Capturing" {
		t.Fatalf("phase = %q, want Capturing", phase)
	}
	uid, _, _ := unstructured.NestedString(current.Object, "status", "sourceUID")
	generation, _, _ := unstructured.NestedInt64(current.Object, "status", "sourceGeneration")
	if uid != "uid-source" || generation != 3 || backend.created != 1 {
		t.Fatalf("checkpoint uid=%q generation=%d created=%d", uid, generation, backend.created)
	}

	backend.state = vmtemplate.TemplateState{RequestName: op.GetName(), TemplateName: "gold", Ready: true}
	if _, err := r.Reconcile(ctx, ctrl.Request{NamespacedName: client.ObjectKeyFromObject(op)}); err != nil {
		t.Fatalf("ready reconcile: %v", err)
	}
	current = getOperation(t, ctx, c, op.GetNamespace(), op.GetName())
	if phase, _, _ := unstructured.NestedString(current.Object, "status", "phase"); phase != "Ready" {
		t.Fatalf("phase = %q, want Ready", phase)
	}
	if err := c.Get(ctx, client.ObjectKeyFromObject(source), sourceVMInstance("", "", 0)); err != nil {
		t.Fatalf("copy unexpectedly removed source VMInstance: %v", err)
	}
}

func TestConvertRefusesSourceChangedAfterCapture(t *testing.T) {
	ctx := context.Background()
	op := operationObject("Convert")
	setCheckpoint(op, "old-uid", 2)
	source := sourceVMInstance("source", "new-uid", 3)
	c := fakeClient(t, op, source)
	backend := &fakeBackend{state: vmtemplate.TemplateState{RequestName: op.GetName(), TemplateName: "gold", Ready: true}}
	r := &Reconciler{Client: c, Backend: backend}

	if _, err := r.Reconcile(ctx, ctrl.Request{NamespacedName: client.ObjectKeyFromObject(op)}); err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	current := getOperation(t, ctx, c, op.GetNamespace(), op.GetName())
	if phase, _, _ := unstructured.NestedString(current.Object, "status", "phase"); phase != "Failed" {
		t.Fatalf("phase = %q, want Failed", phase)
	}
	check := sourceVMInstance("", "", 0)
	check.SetNamespace(source.GetNamespace())
	check.SetName(source.GetName())
	if err := c.Get(ctx, client.ObjectKeyFromObject(source), check); err != nil {
		t.Fatalf("changed source should remain: %v", err)
	}
}

func TestConvertDeletesMatchingSourceOnlyAfterReadyAndRecovers(t *testing.T) {
	ctx := context.Background()
	op := operationObject("Convert")
	setCheckpoint(op, "uid-source", 3)
	source := sourceVMInstance("source", "uid-source", 3)
	c := fakeClient(t, op, source)
	backend := &fakeBackend{state: vmtemplate.TemplateState{RequestName: op.GetName(), TemplateName: "gold", Ready: true}}
	r := &Reconciler{Client: c, Backend: backend, RequeueAfter: time.Millisecond}

	if _, err := r.Reconcile(ctx, ctrl.Request{NamespacedName: client.ObjectKeyFromObject(op)}); err != nil {
		t.Fatalf("delete reconcile: %v", err)
	}
	check := sourceVMInstance("", "", 0)
	check.SetNamespace(source.GetNamespace())
	check.SetName(source.GetName())
	if err := c.Get(ctx, client.ObjectKeyFromObject(source), check); !apierrors.IsNotFound(err) {
		t.Fatalf("source still exists or unexpected error after verified conversion: %v", err)
	}

	// Simulates a controller crash after the source deletion and before a final
	// Ready checkpoint. The next reconcile sees native Ready + source absent.
	if _, err := r.Reconcile(ctx, ctrl.Request{NamespacedName: client.ObjectKeyFromObject(op)}); err != nil {
		t.Fatalf("recovery reconcile: %v", err)
	}
	current := getOperation(t, ctx, c, op.GetNamespace(), op.GetName())
	phase, _, _ := unstructured.NestedString(current.Object, "status", "phase")
	converted, _, _ := unstructured.NestedBool(current.Object, "status", "converted")
	if phase != "Ready" || !converted {
		t.Fatalf("recovered phase=%q converted=%t", phase, converted)
	}
}

func TestResolveNamespacesDeniesTenantEscapeAndUnsafeGlobalConvert(t *testing.T) {
	if _, _, err := resolveNamespaces("tenant-a", operationSpec{Scope: "Tenant", SourceNamespace: "tenant-b"}); err == nil {
		t.Fatal("tenant namespace escape should be rejected")
	}
	if _, _, err := resolveNamespaces("tenant-a", operationSpec{Scope: "Global", SourceNamespace: "tenant-a", Mode: "Copy"}); err == nil {
		t.Fatal("global promotion outside cozy-system should be rejected")
	}
	if _, _, err := resolveNamespaces(globalOperationNamespace, operationSpec{Scope: "Global", SourceNamespace: "tenant-a", Mode: "Convert"}); err == nil {
		t.Fatal("global destructive convert should be rejected")
	}
	if source, target, err := resolveNamespaces(globalOperationNamespace, operationSpec{Scope: "Global", SourceNamespace: "tenant-a", Mode: "Copy", AllowSecretReferences: false}); err != nil || source != "tenant-a" || target != globalTemplateNamespace {
		t.Fatalf("safe global promotion resolution source=%q target=%q err=%v", source, target, err)
	}
}

func operationObject(mode string) *unstructured.Unstructured {
	op := &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "virtualization.cozystack.io/v1alpha1",
		"kind":       "VMTemplateOperation",
		"metadata": map[string]interface{}{
			"name":       "vm-template-gold",
			"namespace":  "tenant-test",
			"generation": int64(1),
			"finalizers": []interface{}{OperationFinalizer},
		},
		"spec": map[string]interface{}{
			"sourceVM":              "source",
			"templateName":          "gold",
			"mode":                  mode,
			"scope":                 "Tenant",
			"excludeOpticalMedia":   true,
			"allowSecretReferences": true,
			"requireHalted":         true,
		},
	}}
	op.SetGroupVersionKind(OperationGVK)
	return op
}

func setCheckpoint(op *unstructured.Unstructured, uid string, generation int64) {
	op.Object["status"] = map[string]interface{}{
		"sourceUID":        uid,
		"sourceGeneration": generation,
		"phase":            "Capturing",
	}
}

func sourceVMInstance(name, uid string, generation int64) *unstructured.Unstructured {
	obj := &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "apps.cozystack.io/v1alpha1",
		"kind":       "VMInstance",
		"metadata": map[string]interface{}{
			"name":            name,
			"namespace":       "tenant-test",
			"uid":             uid,
			"generation":      generation,
			"resourceVersion": "1",
		},
		"spec": map[string]interface{}{},
	}}
	obj.SetGroupVersionKind(vmInstanceGVK)
	return obj
}

func kubeVirtVM(source string) *unstructured.Unstructured {
	obj := &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "kubevirt.io/v1",
		"kind":       "VirtualMachine",
		"metadata": map[string]interface{}{
			"name":      "vm-instance-" + source,
			"namespace": "tenant-test",
			"labels": map[string]interface{}{
				"app.kubernetes.io/instance": vmInstanceReleasePrefix + source,
			},
		},
	}}
	return obj
}

func fakeClient(t *testing.T, objects ...client.Object) client.Client {
	t.Helper()
	scheme := runtime.NewScheme()
	builder := fake.NewClientBuilder().WithScheme(scheme).WithObjects(objects...)
	for _, obj := range objects {
		if obj.GetObjectKind().GroupVersionKind() == OperationGVK {
			builder = builder.WithStatusSubresource(obj)
		}
	}
	return builder.Build()
}

func getOperation(t *testing.T, ctx context.Context, c client.Client, namespace, name string) *unstructured.Unstructured {
	t.Helper()
	obj := &unstructured.Unstructured{}
	obj.SetGroupVersionKind(OperationGVK)
	if err := c.Get(ctx, types.NamespacedName{Namespace: namespace, Name: name}, obj); err != nil {
		t.Fatalf("get operation: %v", err)
	}
	return obj
}

var _ = fmt.Sprintf
