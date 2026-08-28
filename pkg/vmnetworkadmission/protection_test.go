// SPDX-License-Identifier: Apache-2.0

package vmnetworkadmission

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	admissionv1 "k8s.io/api/admission/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	dynamicfake "k8s.io/client-go/dynamic/fake"
)

func TestProtectionControllerAddsFinalizer(t *testing.T) {
	network := newVMNetworkForProtection("tenant-a", "prod")
	listKinds := map[schema.GroupVersionResource]string{vmNetworkGVR: "VMNetworkList"}
	dyn := dynamicfake.NewSimpleDynamicClientWithCustomListKinds(runtime.NewScheme(), listKinds, network)

	if err := ReconcileProtectionOnce(context.Background(), dyn, fakeDependencyReader{}); err != nil {
		t.Fatalf("reconcile protection: %v", err)
	}
	got, err := dyn.Resource(vmNetworkGVR).Namespace("tenant-a").Get(context.Background(), "prod", metav1.GetOptions{})
	if err != nil {
		t.Fatalf("get protected network: %v", err)
	}
	if !containsString(got.GetFinalizers(), VMNetworkProtectionFinalizer) {
		t.Fatalf("finalizers=%v, missing %q", got.GetFinalizers(), VMNetworkProtectionFinalizer)
	}
}

func TestProtectionControllerRetainsFinalizerWhileReferenced(t *testing.T) {
	network := newVMNetworkForProtection("tenant-a", "prod")
	now := metav1.NewTime(time.Now().UTC())
	network.SetDeletionTimestamp(&now)
	network.SetFinalizers([]string{VMNetworkProtectionFinalizer})
	listKinds := map[schema.GroupVersionResource]string{vmNetworkGVR: "VMNetworkList"}
	dyn := dynamicfake.NewSimpleDynamicClientWithCustomListKinds(runtime.NewScheme(), listKinds, network)

	if err := ReconcileProtectionOnce(context.Background(), dyn, fakeDependencyReader{vms: []string{"web"}}); err != nil {
		t.Fatalf("reconcile protection: %v", err)
	}
	got, err := dyn.Resource(vmNetworkGVR).Namespace("tenant-a").Get(context.Background(), "prod", metav1.GetOptions{})
	if err != nil {
		t.Fatalf("get protected network: %v", err)
	}
	if !containsString(got.GetFinalizers(), VMNetworkProtectionFinalizer) {
		t.Fatalf("referenced deleting network lost protection finalizer: %v", got.GetFinalizers())
	}
}

func TestDeleteWithoutProtectionFinalizerDenied(t *testing.T) {
	review := vmNetworkReview(admissionv1.Delete,
		`{"metadata":{"name":"prod","namespace":"tenant-a"}}`, `{}`,
		"system:serviceaccount:tenant-a:user")
	resp := invokeProtection(t, fakeDependencyReader{}, "system:serviceaccount:cozy-system:vm-network-admission", review)
	if resp.Allowed || resp.Result == nil || resp.Result.Code != http.StatusConflict || !strings.Contains(resp.Result.Message, "not yet covered") {
		t.Fatalf("unprotected delete result allowed=%v result=%+v", resp.Allowed, resp.Result)
	}
}

func TestTenantCannotStripProtectionFinalizer(t *testing.T) {
	review := vmNetworkReview(admissionv1.Update,
		`{"metadata":{"name":"prod","namespace":"tenant-a","finalizers":["`+VMNetworkProtectionFinalizer+`"]}}`,
		`{"metadata":{"name":"prod","namespace":"tenant-a","finalizers":[]}}`,
		"system:serviceaccount:tenant-a:user")
	resp := invokeProtection(t, fakeDependencyReader{}, "system:serviceaccount:cozy-system:vm-network-admission", review)
	if resp.Allowed || resp.Result == nil || resp.Result.Code != http.StatusForbidden {
		t.Fatalf("tenant finalizer removal result allowed=%v result=%+v", resp.Allowed, resp.Result)
	}
}

func TestOnlyControllerCanReleaseDeletingNetworkFinalizer(t *testing.T) {
	stamp := time.Now().UTC().Format(time.RFC3339)
	old := `{"metadata":{"name":"prod","namespace":"tenant-a","deletionTimestamp":"` + stamp + `","finalizers":["` + VMNetworkProtectionFinalizer + `"]}}`
	newObj := `{"metadata":{"name":"prod","namespace":"tenant-a","deletionTimestamp":"` + stamp + `","finalizers":[]}}`

	review := vmNetworkReview(admissionv1.Update, old, newObj, "system:serviceaccount:tenant-a:user")
	resp := invokeProtection(t, fakeDependencyReader{}, "system:serviceaccount:cozy-system:vm-network-admission", review)
	if resp.Allowed || resp.Result == nil || resp.Result.Code != http.StatusForbidden {
		t.Fatalf("non-controller deleting finalizer removal allowed=%v result=%+v", resp.Allowed, resp.Result)
	}

	review = vmNetworkReview(admissionv1.Update, old, newObj, "system:serviceaccount:cozy-system:vm-network-admission")
	resp = invokeProtection(t, fakeDependencyReader{vms: []string{"web"}}, "system:serviceaccount:cozy-system:vm-network-admission", review)
	if resp.Allowed || resp.Result == nil || resp.Result.Code != http.StatusConflict {
		t.Fatalf("controller release with references allowed=%v result=%+v", resp.Allowed, resp.Result)
	}
}

func newVMNetworkForProtection(namespace, name string) *unstructured.Unstructured {
	o := &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "apps.cozystack.io/v1alpha1",
		"kind":       "VMNetwork",
		"metadata": map[string]interface{}{
			"namespace": namespace,
			"name":      name,
		},
	}}
	o.SetGroupVersionKind(vmNetworkGVR.GroupVersion().WithKind("VMNetwork"))
	return o
}

func vmNetworkReview(op admissionv1.Operation, oldObject, object, username string) admissionv1.AdmissionReview {
	return admissionv1.AdmissionReview{
		TypeMeta: metav1.TypeMeta{APIVersion: admissionv1.SchemeGroupVersion.String(), Kind: "AdmissionReview"},
		Request: &admissionv1.AdmissionRequest{
			UID:       types.UID("protect-test"),
			Operation: op,
			Namespace: "tenant-a",
			Name:      "prod",
			Resource:  metav1.GroupVersionResource{Group: appsGroup, Version: "v1alpha1", Resource: vmNetworkResource},
			OldObject: runtime.RawExtension{Raw: []byte(oldObject)},
			Object:    runtime.RawExtension{Raw: []byte(object)},
			UserInfo:  authenticationInfo(username),
		},
	}
}

func authenticationInfo(username string) authenticationv1.UserInfo {
	return authenticationv1.UserInfo{Username: username}
}

func invokeProtection(t *testing.T, deps DependencyReader, remover string, review admissionv1.AdmissionReview) *admissionv1.AdmissionResponse {
	t.Helper()
	payload, err := json.Marshal(review)
	if err != nil {
		t.Fatalf("marshal review: %v", err)
	}
	next := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		writeProtectionResponse(w, review.Request.UID, allow())
	})
	r := httptest.NewRequest(http.MethodPost, "/validate-vmnetwork", bytes.NewReader(payload))
	w := httptest.NewRecorder()
	NewProtectionAdmissionHandler(deps, remover, next).ServeHTTP(w, r)
	var out admissionv1.AdmissionReview
	if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode response: %v; body=%s", err, w.Body.String())
	}
	if out.Response == nil {
		t.Fatalf("response is nil; body=%s", w.Body.String())
	}
	return out.Response
}
