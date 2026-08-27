// SPDX-License-Identifier: Apache-2.0

package vmnetworkadmission

import (
	"context"
	"errors"
	"strings"
	"testing"

	admissionv1 "k8s.io/api/admission/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	dynamicfake "k8s.io/client-go/dynamic/fake"
)

type fakeDependencyReader struct {
	vms []string
	err error
}

func (f fakeDependencyReader) ReferencingVMInstances(context.Context, string, string) ([]string, error) {
	return f.vms, f.err
}

func request(op admissionv1.Operation, oldSpec, newSpec string) *admissionv1.AdmissionRequest {
	return &admissionv1.AdmissionRequest{
		UID:       types.UID("test"),
		Operation: op,
		Namespace: "tenant-a",
		Name:      "prod",
		Resource:  metav1.GroupVersionResource{Group: appsGroup, Version: "v1alpha1", Resource: vmNetworkResource},
		OldObject: runtime.RawExtension{Raw: []byte(oldSpec)},
		Object:    runtime.RawExtension{Raw: []byte(newSpec)},
	}
}

func TestDeleteDeniedWhenNetworkIsAttached(t *testing.T) {
	h := NewHandler(fakeDependencyReader{vms: []string{"db-01", "web-01"}})
	resp := h.Validate(context.Background(), request(admissionv1.Delete, `{}`, `{}`))
	if resp.Allowed {
		t.Fatal("delete unexpectedly allowed")
	}
	if resp.Result == nil || resp.Result.Code != 409 {
		t.Fatalf("delete result = %+v, want HTTP 409 conflict", resp.Result)
	}
	if !strings.Contains(resp.Result.Message, "db-01, web-01") {
		t.Fatalf("delete message %q does not list dependent VMs", resp.Result.Message)
	}
}

func TestDeleteAllowedWhenNetworkIsUnused(t *testing.T) {
	resp := NewHandler(fakeDependencyReader{}).Validate(context.Background(), request(admissionv1.Delete, `{}`, `{}`))
	if !resp.Allowed {
		t.Fatalf("unused network delete denied: %+v", resp.Result)
	}
}

func TestDependencyLookupFailureFailsClosed(t *testing.T) {
	resp := NewHandler(fakeDependencyReader{err: errors.New("cache unavailable")}).Validate(context.Background(), request(admissionv1.Delete, `{}`, `{}`))
	if resp.Allowed || resp.Result == nil || resp.Result.Code != 500 {
		t.Fatalf("dependency failure must deny with 500, got allowed=%v result=%+v", resp.Allowed, resp.Result)
	}
}

func TestDescriptionOnlyUpdateAllowedWhileAttached(t *testing.T) {
	h := NewHandler(fakeDependencyReader{vms: []string{"vm-01"}})
	resp := h.Validate(context.Background(), request(admissionv1.Update,
		`{"spec":{"bridge":"br120","vlan":120,"description":"old"}}`,
		`{"spec":{"bridge":"br120","vlan":120,"description":"new"}}`))
	if !resp.Allowed {
		t.Fatalf("description-only update denied: %+v", resp.Result)
	}
}

func TestDataplaneUpdateDeniedWhileAttached(t *testing.T) {
	h := NewHandler(fakeDependencyReader{vms: []string{"vm-01"}})
	resp := h.Validate(context.Background(), request(admissionv1.Update,
		`{"spec":{"bridge":"br120","vlan":120,"mtu":1500}}`,
		`{"spec":{"bridge":"br121","vlan":121,"mtu":1500}}`))
	if resp.Allowed || resp.Result == nil || resp.Result.Code != 409 {
		t.Fatalf("disruptive update must be denied, got allowed=%v result=%+v", resp.Allowed, resp.Result)
	}
}

func TestDynamicDependencyReaderIsTenantScopedAndSupportsLegacySubnets(t *testing.T) {
	listKinds := map[schema.GroupVersionResource]string{helmReleaseGVR: "HelmReleaseList"}
	newHR := func(namespace, releaseName, appName string, values map[string]interface{}) *unstructured.Unstructured {
		o := &unstructured.Unstructured{Object: map[string]interface{}{
			"apiVersion": "helm.toolkit.fluxcd.io/v2",
			"kind":       "HelmRelease",
			"metadata": map[string]interface{}{
				"name":      releaseName,
				"namespace": namespace,
				"labels": map[string]interface{}{
					applicationKindLabel:  vmInstanceKind,
					applicationGroupLabel: appsGroup,
					applicationNameLabel:  appName,
				},
			},
			"spec": map[string]interface{}{"values": values},
		}}
		return o
	}

	dyn := dynamicfake.NewSimpleDynamicClientWithCustomListKinds(runtime.NewScheme(), listKinds,
		newHR("tenant-a", "vm-instance-web", "web", map[string]interface{}{
			"networks": []interface{}{map[string]interface{}{"name": "prod"}},
		}),
		newHR("tenant-a", "vm-instance-db", "db", map[string]interface{}{
			"subnets": []interface{}{map[string]interface{}{"name": "prod"}},
		}),
		newHR("tenant-a", "vm-instance-other", "other", map[string]interface{}{
			"networks": []interface{}{map[string]interface{}{"name": "backup"}},
		}),
		newHR("tenant-b", "vm-instance-secret", "secret", map[string]interface{}{
			"networks": []interface{}{map[string]interface{}{"name": "prod"}},
		}),
	)

	got, err := NewDynamicDependencyReader(dyn).ReferencingVMInstances(context.Background(), "tenant-a", "prod")
	if err != nil {
		t.Fatalf("ReferencingVMInstances: %v", err)
	}
	want := []string{"db", "web"}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("dependencies = %v, want %v", got, want)
	}
}
