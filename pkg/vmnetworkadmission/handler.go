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
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
)

const (
	appsGroup             = "apps.cozystack.io"
	vmNetworkResource     = "vmnetworks"
	vmInstanceResource    = "vminstances"
	vmInstanceKind        = "VMInstance"
	applicationKindLabel  = "apps.cozystack.io/application.kind"
	applicationGroupLabel = "apps.cozystack.io/application.group"
	applicationNameLabel  = "apps.cozystack.io/application.name"
)

var (
	helmReleaseGVR = schema.GroupVersionResource{
		Group: "helm.toolkit.fluxcd.io", Version: "v2", Resource: "helmreleases",
	}
	vmNetworkGVR = schema.GroupVersionResource{
		Group: appsGroup, Version: "v1alpha1", Resource: vmNetworkResource,
	}
	networkFabricGVR = schema.GroupVersionResource{
		Group: "infrastructure.cozystack.io", Version: "v1alpha1", Resource: "networkfabrics",
	}
)

type DependencyReader interface {
	ReferencingVMInstances(ctx context.Context, namespace, networkName string) ([]string, error)
}

type NetworkReferenceReader interface {
	ValidateReferences(ctx context.Context, namespace string, networkNames []string) (valid bool, message string, err error)
}

type FabricBinding struct {
	FabricRef     string
	FabricNetwork string
	Bridge        string
	VLAN          int64
	MTU           int64
}

type FabricReader interface {
	ValidateBinding(ctx context.Context, binding FabricBinding) (valid bool, message string, err error)
}

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

type DynamicNetworkReferenceReader struct {
	dynamic dynamic.Interface
}

func NewDynamicNetworkReferenceReader(dynamicClient dynamic.Interface) *DynamicNetworkReferenceReader {
	return &DynamicNetworkReferenceReader{dynamic: dynamicClient}
}

func (r *DynamicNetworkReferenceReader) ValidateReferences(ctx context.Context, namespace string, networkNames []string) (bool, string, error) {
	if namespace == "" {
		return false, "VMInstance namespace is required for VMNetwork validation", nil
	}
	for _, name := range networkNames {
		network, err := r.dynamic.Resource(vmNetworkGVR).Namespace(namespace).Get(ctx, name, metav1.GetOptions{})
		if err != nil {
			if apierrors.IsNotFound(err) {
				return false, fmt.Sprintf("VMNetwork %q does not exist in namespace %q", name, namespace), nil
			}
			return false, "", fmt.Errorf("get VMNetwork %q in namespace %q: %w", name, namespace, err)
		}
		if network.GetDeletionTimestamp() != nil {
			return false, fmt.Sprintf("VMNetwork %q in namespace %q is being deleted", name, namespace), nil
		}
	}
	return true, "", nil
}

type DynamicFabricReader struct {
	dynamic dynamic.Interface
}

func NewDynamicFabricReader(dynamicClient dynamic.Interface) *DynamicFabricReader {
	return &DynamicFabricReader{dynamic: dynamicClient}
}

func (r *DynamicFabricReader) ValidateBinding(ctx context.Context, binding FabricBinding) (bool, string, error) {
	fabric, err := r.dynamic.Resource(networkFabricGVR).Get(ctx, binding.FabricRef, metav1.GetOptions{})
	if err != nil {
		if apierrors.IsNotFound(err) {
			return false, fmt.Sprintf("NetworkFabric %q does not exist", binding.FabricRef), nil
		}
		return false, "", fmt.Errorf("get NetworkFabric %q: %w", binding.FabricRef, err)
	}

	phase, _, _ := unstructured.NestedString(fabric.Object, "status", "phase")
	observedRaw, found, err := unstructured.NestedFieldNoCopy(fabric.Object, "status", "observedGeneration")
	if err != nil {
		return false, "", fmt.Errorf("read NetworkFabric %q observedGeneration: %w", binding.FabricRef, err)
	}
	if !found {
		return false, fmt.Sprintf("NetworkFabric %q has not reported observedGeneration", binding.FabricRef), nil
	}
	observed, err := numericInt64(observedRaw)
	if err != nil {
		return false, "", fmt.Errorf("read NetworkFabric %q observedGeneration: %w", binding.FabricRef, err)
	}
	if phase != "Ready" || observed != fabric.GetGeneration() {
		return false, fmt.Sprintf("NetworkFabric %q is not Ready at generation %d", binding.FabricRef, fabric.GetGeneration()), nil
	}

	networks, found, err := unstructured.NestedSlice(fabric.Object, "spec", "networks")
	if err != nil {
		return false, "", fmt.Errorf("read NetworkFabric %q networks: %w", binding.FabricRef, err)
	}
	if !found {
		return false, fmt.Sprintf("NetworkFabric %q defines no networks", binding.FabricRef), nil
	}
	for _, raw := range networks {
		network, ok := raw.(map[string]interface{})
		if !ok {
			continue
		}
		name, _ := network["name"].(string)
		if name != binding.FabricNetwork {
			continue
		}
		bridge, _ := network["bridge"].(string)
		vlan, err := numericInt64(network["vlan"])
		if err != nil {
			return false, "", fmt.Errorf("read NetworkFabric %q network %q VLAN: %w", binding.FabricRef, binding.FabricNetwork, err)
		}
		mtu, err := numericInt64Default(network["mtu"], 0)
		if err != nil {
			return false, "", fmt.Errorf("read NetworkFabric %q network %q MTU: %w", binding.FabricRef, binding.FabricNetwork, err)
		}
		if bridge != binding.Bridge || vlan != binding.VLAN || mtu != binding.MTU {
			return false, fmt.Sprintf("VMNetwork dataplane does not match NetworkFabric %q network %q: expected bridge=%s vlan=%d mtu=%d", binding.FabricRef, binding.FabricNetwork, bridge, vlan, mtu), nil
		}
		return true, "", nil
	}
	return false, fmt.Sprintf("NetworkFabric %q does not define network %q", binding.FabricRef, binding.FabricNetwork), nil
}

func numericInt64Default(value interface{}, fallback int64) (int64, error) {
	if value == nil {
		return fallback, nil
	}
	return numericInt64(value)
}

func numericInt64(value interface{}) (int64, error) {
	switch v := value.(type) {
	case int64:
		return v, nil
	case int32:
		return int64(v), nil
	case int:
		return int64(v), nil
	case float64:
		if v != float64(int64(v)) {
			return 0, fmt.Errorf("non-integral value %v", v)
		}
		return int64(v), nil
	case json.Number:
		return v.Int64()
	default:
		return 0, fmt.Errorf("unsupported numeric value %T", value)
	}
}

type Handler struct {
	dependencies DependencyReader
	fabrics      FabricReader
	networks     NetworkReferenceReader
}

func NewHandler(dependencies DependencyReader, fabrics ...FabricReader) *Handler {
	h := &Handler{dependencies: dependencies}
	if len(fabrics) > 0 {
		h.fabrics = fabrics[0]
	}
	return h
}

func (h *Handler) WithNetworkReferenceReader(networks NetworkReferenceReader) *Handler {
	h.networks = networks
	return h
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
	if req.Resource.Group != appsGroup {
		return allow()
	}

	if req.Resource.Resource == vmInstanceResource {
		switch req.Operation {
		case admissionv1.Create, admissionv1.Update:
			return h.validateVMInstanceNetworks(ctx, req.Namespace, req.Object.Raw)
		default:
			return allow()
		}
	}

	if req.Resource.Resource != vmNetworkResource {
		return allow()
	}

	switch req.Operation {
	case admissionv1.Create:
		return h.validateFabric(ctx, req.Object.Raw)
	case admissionv1.Update:
		if resp := h.validateFabric(ctx, req.Object.Raw); !resp.Allowed {
			return resp
		}
		changed, err := disruptiveNetworkChange(req.OldObject.Raw, req.Object.Raw)
		if err != nil {
			return deny(http.StatusBadRequest, metav1.StatusReasonInvalid, fmt.Sprintf("cannot validate VMNetwork update: %v", err))
		}
		if !changed {
			return allow()
		}
		return h.validateUnused(ctx, req.Namespace, req.Name, "change bridge/VLAN/MTU or fabric/interface safety properties of")
	case admissionv1.Delete:
		return h.validateUnused(ctx, req.Namespace, req.Name, "delete")
	default:
		return allow()
	}
}

func (h *Handler) validateVMInstanceNetworks(ctx context.Context, namespace string, raw []byte) *admissionv1.AdmissionResponse {
	names, err := vmInstanceNetworkNames(raw)
	if err != nil {
		return deny(http.StatusBadRequest, metav1.StatusReasonInvalid, fmt.Sprintf("cannot decode VMInstance network references: %v", err))
	}
	if len(names) == 0 {
		return allow()
	}
	if h.networks == nil {
		return deny(http.StatusInternalServerError, metav1.StatusReasonInternalError, "VMNetwork reference reader is not configured")
	}
	valid, message, err := h.networks.ValidateReferences(ctx, namespace, names)
	if err != nil {
		return deny(http.StatusInternalServerError, metav1.StatusReasonInternalError, fmt.Sprintf("cannot validate VMInstance VMNetwork references: %v", err))
	}
	if !valid {
		return deny(http.StatusUnprocessableEntity, metav1.StatusReasonInvalid, message)
	}
	return allow()
}

func vmInstanceNetworkNames(raw []byte) ([]string, error) {
	var object struct {
		Spec map[string]interface{} `json:"spec"`
	}
	if err := json.Unmarshal(raw, &object); err != nil {
		return nil, err
	}
	seen := map[string]struct{}{}
	for _, field := range []string{"networks", "subnets"} {
		attachments, found, err := unstructured.NestedSlice(object.Spec, field)
		if err != nil {
			return nil, fmt.Errorf("read spec.%s: %w", field, err)
		}
		if !found {
			continue
		}
		for i, attachment := range attachments {
			m, ok := attachment.(map[string]interface{})
			if !ok {
				return nil, fmt.Errorf("spec.%s[%d] must be an object", field, i)
			}
			name, _ := m["name"].(string)
			name = strings.TrimSpace(name)
			if name == "" {
				return nil, fmt.Errorf("spec.%s[%d].name is required", field, i)
			}
			seen[name] = struct{}{}
		}
	}
	names := make([]string, 0, len(seen))
	for name := range seen {
		names = append(names, name)
	}
	sort.Strings(names)
	return names, nil
}

func (h *Handler) validateFabric(ctx context.Context, raw []byte) *admissionv1.AdmissionResponse {
	var object struct {
		Spec struct {
			Bridge        string `json:"bridge"`
			VLAN          int64  `json:"vlan"`
			MTU           int64  `json:"mtu"`
			FabricRef     string `json:"fabricRef"`
			FabricNetwork string `json:"fabricNetwork"`
		} `json:"spec"`
	}
	if err := json.Unmarshal(raw, &object); err != nil {
		return deny(http.StatusBadRequest, metav1.StatusReasonInvalid, fmt.Sprintf("cannot decode VMNetwork: %v", err))
	}
	binding := FabricBinding{FabricRef: object.Spec.FabricRef, FabricNetwork: object.Spec.FabricNetwork, Bridge: object.Spec.Bridge, VLAN: object.Spec.VLAN, MTU: object.Spec.MTU}
	if binding.FabricRef == "" && binding.FabricNetwork == "" {
		return allow()
	}
	if binding.FabricRef == "" || binding.FabricNetwork == "" {
		return deny(http.StatusBadRequest, metav1.StatusReasonInvalid, "fabricRef and fabricNetwork must be set together")
	}
	if h.fabrics == nil {
		return deny(http.StatusInternalServerError, metav1.StatusReasonInternalError, "NetworkFabric reader is not configured")
	}
	valid, message, err := h.fabrics.ValidateBinding(ctx, binding)
	if err != nil {
		return deny(http.StatusInternalServerError, metav1.StatusReasonInternalError, fmt.Sprintf("cannot validate NetworkFabric binding: %v", err))
	}
	if !valid {
		return deny(http.StatusUnprocessableEntity, metav1.StatusReasonInvalid, message)
	}
	return allow()
}

func (h *Handler) validateUnused(ctx context.Context, namespace, name, action string) *admissionv1.AdmissionResponse {
	if h.dependencies == nil {
		return deny(http.StatusInternalServerError, metav1.StatusReasonInternalError, "VMNetwork dependency reader is not configured")
	}
	vms, err := h.dependencies.ReferencingVMInstances(ctx, namespace, name)
	if err != nil {
		return deny(http.StatusInternalServerError, metav1.StatusReasonInternalError, fmt.Sprintf("cannot verify whether VMNetwork %q is in use: %v", name, err))
	}
	if len(vms) == 0 {
		return allow()
	}
	return deny(http.StatusConflict, metav1.StatusReasonConflict, fmt.Sprintf("cannot %s VMNetwork %q in namespace %q: attached to VMInstance(s): %s; detach the network from every VM first", action, name, namespace, strings.Join(vms, ", ")))
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
	for _, key := range []string{"bridge", "vlan", "mtu", "promiscMode", "macspoofchk", "hairpinMode", "fabricRef", "fabricNetwork"} {
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
	return &admissionv1.AdmissionResponse{Allowed: false, Result: &metav1.Status{Status: metav1.StatusFailure, Code: int32(code), Reason: reason, Message: message}}
}
