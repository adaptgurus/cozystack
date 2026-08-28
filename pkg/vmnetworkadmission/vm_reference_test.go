// SPDX-License-Identifier: Apache-2.0

package vmnetworkadmission

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	admissionv1 "k8s.io/api/admission/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	dynamicfake "k8s.io/client-go/dynamic/fake"
)

type fakeNetworkReferenceReader struct {
	valid     bool
	message   string
	err       error
	namespace string
	names     []string
}

func (f *fakeNetworkReferenceReader) ValidateReferences(_ context.Context, namespace string, names []string) (bool, string, error) {
	f.namespace = namespace
	f.names = append([]string(nil), names...)
	return f.valid, f.message, f.err
}

func vmInstanceRequest(op admissionv1.Operation, namespace, name, object string) *admissionv1.AdmissionRequest {
	return &admissionv1.AdmissionRequest{
		UID:       types.UID("vm-test"),
		Operation: op,
		Namespace: namespace,
		Name:      name,
		Resource:  metav1.GroupVersionResource{Group: appsGroup, Version: "v1alpha1", Resource: vmInstanceResource},
		Object:    runtime.RawExtension{Raw: []byte(object)},
	}
}

func TestVMInstanceCreateValidatesAllNetworkReferences(t *testing.T) {
	reader := &fakeNetworkReferenceReader{valid: true}
	h := NewHandler(fakeDependencyReader{}).WithNetworkReferenceReader(reader)
	resp := h.Validate(context.Background(), vmInstanceRequest(admissionv1.Create, "tenant-a", "web",
		`{"spec":{"networks":[{"name":"prod"},{"name":"backup"}],"subnets":[{"name":"prod"}]}}`))
	if !resp.Allowed {
		t.Fatalf("valid VMInstance network references denied: %+v", resp.Result)
	}
	if reader.namespace != "tenant-a" || len(reader.names) != 2 || reader.names[0] != "backup" || reader.names[1] != "prod" {
		t.Fatalf("network validation got namespace=%q names=%v", reader.namespace, reader.names)
	}
}

func TestVMInstanceNetworkLookupFailureFailsClosed(t *testing.T) {
	reader := &fakeNetworkReferenceReader{err: errors.New("api unavailable")}
	resp := NewHandler(fakeDependencyReader{}).WithNetworkReferenceReader(reader).Validate(context.Background(), vmInstanceRequest(admissionv1.Update, "tenant-a", "web",
		`{"spec":{"networks":[{"name":"prod"}]}}`))
	if resp.Allowed || resp.Result == nil || resp.Result.Code != 500 {
		t.Fatalf("network lookup failure must deny with 500, allowed=%v result=%+v", resp.Allowed, resp.Result)
	}
}

func TestVMInstanceMissingNetworkDenied(t *testing.T) {
	dyn := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme())
	reader := NewDynamicNetworkReferenceReader(dyn)
	valid, message, err := reader.ValidateReferences(context.Background(), "tenant-a", []string{"prod"})
	if err != nil || valid || !strings.Contains(message, "does not exist") {
		t.Fatalf("missing network result valid=%v message=%q err=%v", valid, message, err)
	}
}

func TestVMInstanceCrossTenantNetworkDenied(t *testing.T) {
	network := &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "apps.cozystack.io/v1alpha1",
		"kind":       "VMNetwork",
		"metadata": map[string]interface{}{
			"name": "prod", "namespace": "tenant-b",
		},
	}}
	network.SetGroupVersionKind(vmNetworkGVR.GroupVersion().WithKind("VMNetwork"))
	dyn := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), network)
	valid, message, err := NewDynamicNetworkReferenceReader(dyn).ValidateReferences(context.Background(), "tenant-a", []string{"prod"})
	if err != nil || valid || !strings.Contains(message, "does not exist") {
		t.Fatalf("cross-tenant reference result valid=%v message=%q err=%v", valid, message, err)
	}
}

func TestVMInstanceDeletingNetworkDenied(t *testing.T) {
	now := metav1.NewTime(time.Now().UTC())
	network := &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "apps.cozystack.io/v1alpha1",
		"kind":       "VMNetwork",
		"metadata": map[string]interface{}{
			"name": "prod", "namespace": "tenant-a",
		},
	}}
	network.SetDeletionTimestamp(&now)
	network.SetFinalizers([]string{VMNetworkProtectionFinalizer})
	network.SetGroupVersionKind(vmNetworkGVR.GroupVersion().WithKind("VMNetwork"))
	dyn := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), network)
	valid, message, err := NewDynamicNetworkReferenceReader(dyn).ValidateReferences(context.Background(), "tenant-a", []string{"prod"})
	if err != nil || valid || !strings.Contains(message, "being deleted") {
		t.Fatalf("deleting network result valid=%v message=%q err=%v", valid, message, err)
	}
}

func TestVMInstanceMalformedNetworkFailsClosed(t *testing.T) {
	resp := NewHandler(fakeDependencyReader{}).WithNetworkReferenceReader(&fakeNetworkReferenceReader{valid: true}).Validate(context.Background(), vmInstanceRequest(admissionv1.Create, "tenant-a", "web",
		`{"spec":{"networks":[{"name":""}]}}`))
	if resp.Allowed || resp.Result == nil || resp.Result.Code != 400 {
		t.Fatalf("malformed network must deny with 400, allowed=%v result=%+v", resp.Allowed, resp.Result)
	}
}
