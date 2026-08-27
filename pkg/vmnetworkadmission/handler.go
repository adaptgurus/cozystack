// SPDX-License-Identifier: Apache-2.0

package vmnetworkadmission

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"reflect"
	"sort"
	"strings"

	admissionv1 "k8s.io/api/admission/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
)

const (
	appsGroup             = "apps.cozystack.io"
	vmNetworkResource     = "vmnetworks"
	vmInstanceKind        = "VMInstance"
	applicationKindLabel  = "apps.cozystack.io/application.kind"
	applicationGroupLabel = "apps.cozystack.io/application.group"
	applicationNameLabel  = "apps.cozystack.io/application.name"
)

var helmReleaseGVR = schema.GroupVersionResource{
	Group: "helm.toolkit.fluxcd.io", Version: "v2", Resource: "helmreleases",
}

// DependencyReader resolves tenant-local VMInstance applications that reference
// a VMNetwork. Implementations MUST scope the lookup to the supplied namespace;
// cross-tenant reads would turn a safety check into an information leak.
type DependencyReader interface {
	ReferencingVMInstances(ctx context.Context, namespace, networkName string) ([]string, error)
}

// DynamicDependencyReader reads the HelmRelease backing objects used by the
// Cozystack Application API. VMInstance network attachments live in
// spec.values.networks; spec.values.subnets is retained for the v1.6 legacy
// compatibility path.
type DynamicDependencyReader struct {
	dynamic dynamic.Interface
}

func NewDynamicDependencyReader(dynamicClient dynamic.Interface) *DynamicDependencyReader {
	return &DynamicDependencyReader{dynamic: dynamicClient}
}

func (r *DynamicDependencyReader) ReferencingVMInstances(ctx context.Context, namespace, networkName string) ([]string, error) {
	if namespace == "" || networkName == "" {
		return nil, nil
	}
	selector := fmt.Sprintf("%s=%s,%s=%s", applicationKindLabel, vmInstanceKind, applicationGroupLabel, appsGroup)
	list, err := r.dynamic.Resource(helmReleaseGVR).Namespace(namespace).List(ctx, metav1.ListOptions{LabelSelector: selector})
	if err != nil {
		return nil, fmt.Errorf("list tenant VMInstance HelmReleases: %w", err)
	}

	seen := map[string]struct{}{}
	for i := range list.Items {
		hr := &list.Items[i]
		values, found, err := unstructured.NestedMap(hr.Object, "spec", "values")
		if err != nil {
			return nil, fmt.Errorf("read HelmRelease %s/%s values: %w", namespace, hr.GetName(), err)
		}
		if !found || !referencesNetwork(values, networkName) {
			continue
		}
		name := hr.GetLabels()[applicationNameLabel]
		if name == "" {
			name = hr.GetName()
		}
		seen[name] = struct{}{}
	}

	out := make([]string, 0, len(seen))
	for name := range seen {
		out = append(out, name)
	}
	sort.Strings(out)
	return out, nil
}

func referencesNetwork(values map[string]interface{}, networkName string) bool {
	for _, field := range []string{"networks", "subnets"} {
		attachments, found, err := unstructured.NestedSlice(values, field)
		if err != nil || !found {
			continue
		}
		for _, attachment := range attachments {
			m, ok := attachment.(map[string]interface{})
			if !ok {
				continue
			}
			if name, _ := m["name"].(string); name == networkName {
				return true
			}
		}
	}
	return false
}

// Handler validates disruptive VMNetwork changes and deletion. It deliberately
// does not validate host bridge existence: that belongs to the NetworkFabric / 
// Talos platform reconciler, not a tenant-scoped admission request.
type Handler struct {
	dependencies DependencyReader
}

func NewHandler(dependencies DependencyReader) *Handler {
	return &Handler{dependencies: dependencies}
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "admission endpoint requires POST", http.StatusMethodNotAllowed)
		return
	}
	defer r.Body.Close()

	var review admissionv1.AdmissionReview
	if err := json.NewDecoder(r.Body).Decode(&review); err != nil {
		http.Error(w, fmt.Sprintf("decode AdmissionReview: %v", err), http.StatusBadRequest)
		return
	}
	if review.Request == nil {
		http.Error(w, "AdmissionReview.request is required", http.StatusBadRequest)
		return
	}

	response := h.Validate(r.Context(), review.Request)
	response.UID = review.Request.UID
	out := admissionv1.AdmissionReview{
		TypeMeta: metav1.TypeMeta{APIVersion: admissionv1.SchemeGroupVersion.String(), Kind: "AdmissionReview"},
		Response: response,
	}
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(&out); err != nil {
		http.Error(w, fmt.Sprintf("encode AdmissionReview: %v", err), http.StatusInternalServerError)
	}
}

func (h *Handler) Validate(ctx context.Context, req *admissionv1.AdmissionRequest) *admissionv1.AdmissionResponse {
	// Defensive allow for resources outside this webhook's declared scope.
	if req.Resource.Group != appsGroup || req.Resource.Resource != vmNetworkResource {
		return allow()
	}

	switch req.Operation {
	case admissionv1.Delete:
		return h.validateUnused(ctx, req.Namespace, req.Name, "delete")
	case admissionv1.Update:
		changed, err := disruptiveNetworkChange(req.OldObject.Raw, req.Object.Raw)
		if err != nil {
			return deny(http.StatusBadRequest, metav1.StatusReasonInvalid, fmt.Sprintf("cannot validate VMNetwork update: %v", err))
		}
		if !changed {
			return allow()
		}
		return h.validateUnused(ctx, req.Namespace, req.Name, "change bridge/VLAN/MTU or interface safety properties of")
	default:
		return allow()
	}
}

func (h *Handler) validateUnused(ctx context.Context, namespace, name, action string) *admissionv1.AdmissionResponse {
	if h.dependencies == nil {
		return deny(http.StatusInternalServerError, metav1.StatusReasonInternalError, "VMNetwork dependency reader is not configured")
	}
	vms, err := h.dependencies.ReferencingVMInstances(ctx, namespace, name)
	if err != nil {
		// Fail closed. Losing the dependency lookup must never turn into permission
		// to destroy a network that may still back running VMs.
		return deny(http.StatusInternalServerError, metav1.StatusReasonInternalError,
			fmt.Sprintf("cannot verify whether VMNetwork %q is in use: %v", name, err))
	}
	if len(vms) == 0 {
		return allow()
	}
	return deny(http.StatusConflict, metav1.StatusReasonConflict,
		fmt.Sprintf("cannot %s VMNetwork %q in namespace %q: attached to VMInstance(s): %s; detach the network from every VM first",
			action, name, namespace, strings.Join(vms, ", ")))
}

func disruptiveNetworkChange(oldRaw, newRaw []byte) (bool, error) {
	var oldObj, newObj struct {
		Spec map[string]interface{} `json:"spec"`
	}
	if err := json.Unmarshal(oldRaw, &oldObj); err != nil {
		return false, fmt.Errorf("decode old object: %w", err)
	}
	if err := json.Unmarshal(newRaw, &newObj); err != nil {
		return false, fmt.Errorf("decode new object: %w", err)
	}
	// Description is intentionally not included: cosmetic edits remain safe
	// while the network is attached. Every dataplane-affecting property is
	// protected until all VM attachments are removed.
	for _, key := range []string{"bridge", "vlan", "mtu", "promiscMode", "macspoofchk", "hairpinMode", "fabricRef"} {
		if !reflect.DeepEqual(oldObj.Spec[key], newObj.Spec[key]) {
			return true, nil
		}
	}
	return false, nil
}

func allow() *admissionv1.AdmissionResponse {
	return &admissionv1.AdmissionResponse{Allowed: true}
}

func deny(code int, reason metav1.StatusReason, message string) *admissionv1.AdmissionResponse {
	return &admissionv1.AdmissionResponse{
		Allowed: false,
		Result: &metav1.Status{
			Status:  metav1.StatusFailure,
			Code:    int32(code),
			Reason:  reason,
			Message: message,
		},
	}
}
