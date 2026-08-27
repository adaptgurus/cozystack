// SPDX-License-Identifier: Apache-2.0

package vmnetworkadmission

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	admissionv1 "k8s.io/api/admission/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
)

func strictAdmissionBody(t *testing.T, op admissionv1.Operation, group, resource, namespace, name, uid string, object, oldObject []byte) []byte {
	t.Helper()
	review := admissionv1.AdmissionReview{Request: &admissionv1.AdmissionRequest{
		UID:       types.UID(uid),
		Operation: op,
		Resource:  metav1.GroupVersionResource{Group: group, Version: "v1alpha1", Resource: resource},
		Namespace: namespace,
		Name:      name,
		Object:    runtime.RawExtension{Raw: object},
		OldObject: runtime.RawExtension{Raw: oldObject},
	}}
	body, err := json.Marshal(review)
	if err != nil {
		t.Fatalf("marshal AdmissionReview: %v", err)
	}
	return body
}

func TestStrictHandlerAllowsWellFormedVMNetworkAdmission(t *testing.T) {
	called := false
	next := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		called = true
		w.WriteHeader(http.StatusNoContent)
	})
	h := NewStrictHandler(next, DefaultMaxAdmissionBodyBytes)
	body := strictAdmissionBody(t, admissionv1.Create, appsGroup, vmNetworkResource, "tenant-a", "net-a", "uid-1", []byte(`{"spec":{}}`), nil)
	req := httptest.NewRequest(http.MethodPost, "/validate-vmnetwork", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json; charset=utf-8")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusNoContent || !called {
		t.Fatalf("code=%d called=%v, want 204/true; body=%q", resp.Code, called, resp.Body.String())
	}
}

func TestStrictHandlerFailsClosedOnMalformedRequests(t *testing.T) {
	validObject := []byte(`{"spec":{}}`)
	tests := []struct {
		name        string
		method      string
		contentType string
		body        []byte
		wantCode    int
	}{
		{
			name:        "wrong method",
			method:      http.MethodGet,
			contentType: "application/json",
			body:        []byte(`{}`),
			wantCode:    http.StatusMethodNotAllowed,
		},
		{
			name:        "wrong content type",
			method:      http.MethodPost,
			contentType: "text/plain",
			body:        []byte(`{}`),
			wantCode:    http.StatusUnsupportedMediaType,
		},
		{
			name:        "invalid json",
			method:      http.MethodPost,
			contentType: "application/json",
			body:        []byte(`{"request":`),
			wantCode:    http.StatusBadRequest,
		},
		{
			name:        "missing request identity",
			method:      http.MethodPost,
			contentType: "application/json",
			body:        strictAdmissionBody(t, admissionv1.Create, appsGroup, vmNetworkResource, "tenant-a", "", "uid-1", validObject, nil),
			wantCode:    http.StatusBadRequest,
		},
		{
			name:        "wrong resource",
			method:      http.MethodPost,
			contentType: "application/json",
			body:        strictAdmissionBody(t, admissionv1.Create, appsGroup, "otherresources", "tenant-a", "net-a", "uid-1", validObject, nil),
			wantCode:    http.StatusBadRequest,
		},
		{
			name:        "unsupported operation",
			method:      http.MethodPost,
			contentType: "application/json",
			body:        strictAdmissionBody(t, admissionv1.Connect, appsGroup, vmNetworkResource, "tenant-a", "net-a", "uid-1", validObject, nil),
			wantCode:    http.StatusBadRequest,
		},
		{
			name:        "update missing old object",
			method:      http.MethodPost,
			contentType: "application/json",
			body:        strictAdmissionBody(t, admissionv1.Update, appsGroup, vmNetworkResource, "tenant-a", "net-a", "uid-1", validObject, nil),
			wantCode:    http.StatusBadRequest,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			called := false
			h := NewStrictHandler(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				called = true
				w.WriteHeader(http.StatusNoContent)
			}), DefaultMaxAdmissionBodyBytes)
			req := httptest.NewRequest(tt.method, "/validate-vmnetwork", bytes.NewReader(tt.body))
			if tt.contentType != "" {
				req.Header.Set("Content-Type", tt.contentType)
			}
			resp := httptest.NewRecorder()
			h.ServeHTTP(resp, req)
			if resp.Code != tt.wantCode || called {
				t.Fatalf("code=%d called=%v, want %d/false; body=%q", resp.Code, called, tt.wantCode, resp.Body.String())
			}
		})
	}
}

func TestStrictHandlerRejectsOversizedAdmissionBody(t *testing.T) {
	called := false
	h := NewStrictHandler(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { called = true }), 256)
	req := httptest.NewRequest(http.MethodPost, "/validate-vmnetwork", strings.NewReader(strings.Repeat("x", 257)))
	req.Header.Set("Content-Type", "application/json")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusRequestEntityTooLarge || called {
		t.Fatalf("code=%d called=%v, want 413/false", resp.Code, called)
	}
}
