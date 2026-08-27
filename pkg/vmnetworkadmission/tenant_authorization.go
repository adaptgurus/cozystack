// SPDX-License-Identifier: Apache-2.0

package vmnetworkadmission

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"

	"github.com/cozystack/cozystack/pkg/tenantresolver"
	admissionv1 "k8s.io/api/admission/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/dynamic"
)

// NewTenantAuthorizationHandler enforces explicit NetworkFabric tenant grants
// before the normal binding validator runs. NetworkFabric spec.networks[].
// allowedTenants contains Tenant API object references, and every reference is
// resolved through Tenant.status.namespace. Namespace naming conventions are
// never treated as authorization evidence.
func NewTenantAuthorizationHandler(dynamicClient dynamic.Interface, next http.Handler) http.Handler {
	resolver := tenantresolver.New(dynamicClient, nil)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "cannot read AdmissionReview", http.StatusBadRequest)
			return
		}
		_ = r.Body.Close()

		var review admissionv1.AdmissionReview
		if err := json.Unmarshal(body, &review); err != nil || review.Request == nil {
			http.Error(w, "invalid AdmissionReview", http.StatusBadRequest)
			return
		}

		req := review.Request
		if req.Operation == admissionv1.Create || req.Operation == admissionv1.Update {
			var object struct {
				Spec struct {
					FabricRef     string `json:"fabricRef"`
					FabricNetwork string `json:"fabricNetwork"`
				} `json:"spec"`
			}
			if err := json.Unmarshal(req.Object.Raw, &object); err != nil {
				writeTenantAuthorizationResponse(w, req.UID, deny(http.StatusBadRequest, metav1.StatusReasonInvalid, "cannot decode VMNetwork for tenant authorization"))
				return
			}
			if object.Spec.FabricRef != "" && object.Spec.FabricNetwork != "" {
				allowed, authErr := tenantNamespaceAllowed(r.Context(), dynamicClient, resolver, req.Namespace, object.Spec.FabricRef, object.Spec.FabricNetwork)
				if authErr != nil {
					writeTenantAuthorizationResponse(w, req.UID, deny(http.StatusInternalServerError, metav1.StatusReasonInternalError, "cannot verify NetworkFabric tenant authorization"))
					return
				}
				if !allowed {
					writeTenantAuthorizationResponse(w, req.UID, deny(http.StatusForbidden, metav1.StatusReasonForbidden, "tenant is not authorized to consume the requested NetworkFabric network"))
					return
				}
			}
		}

		r.Body = io.NopCloser(bytes.NewReader(body))
		r.ContentLength = int64(len(body))
		next.ServeHTTP(w, r)
	})
}

func tenantNamespaceAllowed(ctx context.Context, dynamicClient dynamic.Interface, resolver *tenantresolver.Resolver, workloadNamespace, fabricName, networkName string) (bool, error) {
	if dynamicClient == nil || resolver == nil {
		return false, fmt.Errorf("tenant authorization client is not configured")
	}
	if workloadNamespace == "" || fabricName == "" || networkName == "" {
		return false, nil
	}

	fabric, err := dynamicClient.Resource(networkFabricGVR).Get(ctx, fabricName, metav1.GetOptions{})
	if err != nil {
		return false, fmt.Errorf("get NetworkFabric for tenant authorization: %w", err)
	}
	networks, found, err := unstructured.NestedSlice(fabric.Object, "spec", "networks")
	if err != nil {
		return false, fmt.Errorf("read NetworkFabric networks for tenant authorization: %w", err)
	}
	if !found {
		return false, nil
	}

	for _, raw := range networks {
		network, ok := raw.(map[string]interface{})
		if !ok {
			continue
		}
		name, _ := network["name"].(string)
		if name != networkName {
			continue
		}
		grants, found, err := unstructured.NestedSlice(network, "allowedTenants")
		if err != nil {
			return false, fmt.Errorf("read NetworkFabric tenant grants: %w", err)
		}
		if !found || len(grants) == 0 {
			return false, nil
		}
		for _, rawGrant := range grants {
			grant, ok := rawGrant.(map[string]interface{})
			if !ok {
				return false, fmt.Errorf("NetworkFabric contains malformed tenant grant")
			}
			controlNamespace, _ := grant["controlNamespace"].(string)
			tenantName, _ := grant["name"].(string)
			if controlNamespace == "" || tenantName == "" {
				return false, fmt.Errorf("NetworkFabric contains incomplete tenant grant")
			}
			resolvedNamespace, err := resolver.ResolveTenantNamespace(ctx, tenantresolver.Ref{ControlNamespace: controlNamespace, Name: tenantName})
			if err != nil {
				return false, fmt.Errorf("resolve NetworkFabric tenant grant: %w", err)
			}
			if resolvedNamespace == workloadNamespace {
				return true, nil
			}
		}
		return false, nil
	}

	return false, nil
}

func writeTenantAuthorizationResponse(w http.ResponseWriter, uid types.UID, response *admissionv1.AdmissionResponse) {
	response.UID = uid
	review := admissionv1.AdmissionReview{
		TypeMeta: metav1.TypeMeta{APIVersion: admissionv1.SchemeGroupVersion.String(), Kind: "AdmissionReview"},
		Response: response,
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(&review)
}
