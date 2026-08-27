// SPDX-License-Identifier: Apache-2.0

package vmtemplate

import (
	"context"
	"fmt"
	"sort"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
)

var (
	gvrKubeVirt = schema.GroupVersionResource{Group: "kubevirt.io", Version: "v1", Resource: "kubevirts"}
	gvrVM       = schema.GroupVersionResource{Group: "kubevirt.io", Version: "v1", Resource: "virtualmachines"}
	gvrVMI      = schema.GroupVersionResource{Group: "kubevirt.io", Version: "v1", Resource: "virtualmachineinstances"}
	gvrTemplate = schema.GroupVersionResource{Group: "template.kubevirt.io", Version: "v1alpha1", Resource: "virtualmachinetemplates"}
	gvrRequest  = schema.GroupVersionResource{Group: "template.kubevirt.io", Version: "v1alpha1", Resource: "virtualmachinetemplaterequests"}
)

const (
	kubeVirtNamespace = "cozy-kubevirt"
	managedByLabel     = "virtualization.cozystack.io/managed-by"
	managedByValue     = "vm-template-controller"
)

type Capabilities struct {
	SnapshotGate       bool
	TemplateGate       bool
	TemplateDeployment bool
}

func (c Capabilities) NativeTemplatesReady() bool {
	return c.SnapshotGate && c.TemplateGate && c.TemplateDeployment
}

type TemplateRef struct {
	Namespace string
	Name      string
}

type CreateRequest struct {
	Namespace    string
	RequestName  string
	TemplateName string
	SourceVMName string
}

// TemplateState has an empty RequestName when no capture request exists yet.
// This lets a controller restart distinguish "not started" from "in progress"
// without relying on process-local state.
type TemplateState struct {
	RequestName  string
	TemplateName string
	Ready        bool
}

type Backend interface {
	DiscoverCapabilities(context.Context) (Capabilities, error)
	ValidateSource(context.Context, TemplateRef, SourcePolicy) (SourceSummary, error)
	CreateTemplate(context.Context, CreateRequest) (TemplateState, error)
	VerifyTemplate(context.Context, TemplateRef, string) (TemplateState, error)
	DeleteTemplate(context.Context, TemplateRef, string) error
}

// KubeVirtTemplateBackend uses unstructured/dynamic clients so the stable
// Cozystack product API is not compiled against KubeVirt's alpha template Go
// API. The exact v1.8.4 resource shape is still verified by tests and the HCI
// feature-gate render gate.
type KubeVirtTemplateBackend struct {
	Client dynamic.Interface
}

func (b *KubeVirtTemplateBackend) DiscoverCapabilities(ctx context.Context) (Capabilities, error) {
	if b == nil || b.Client == nil {
		return Capabilities{}, fmt.Errorf("Kubernetes dynamic client is required")
	}
	kv, err := b.Client.Resource(gvrKubeVirt).Namespace(kubeVirtNamespace).Get(ctx, "kubevirt", metav1.GetOptions{})
	if err != nil {
		return Capabilities{}, fmt.Errorf("get KubeVirt capability configuration: %w", err)
	}
	gatesRaw, _, err := unstructured.NestedSlice(kv.Object, "spec", "configuration", "developerConfiguration", "featureGates")
	if err != nil {
		return Capabilities{}, fmt.Errorf("read KubeVirt feature gates: %w", err)
	}
	gates := map[string]bool{}
	for _, raw := range gatesRaw {
		if gate, ok := raw.(string); ok {
			gates[gate] = true
		}
	}
	enabled, _, err := unstructured.NestedBool(kv.Object, "spec", "configuration", "virtTemplateDeployment", "enabled")
	if err != nil {
		return Capabilities{}, fmt.Errorf("read KubeVirt virtTemplateDeployment capability: %w", err)
	}
	return Capabilities{SnapshotGate: gates["Snapshot"], TemplateGate: gates["Template"], TemplateDeployment: enabled}, nil
}

func (b *KubeVirtTemplateBackend) ValidateSource(ctx context.Context, ref TemplateRef, policy SourcePolicy) (SourceSummary, error) {
	if b == nil || b.Client == nil {
		return SourceSummary{}, fmt.Errorf("Kubernetes dynamic client is required")
	}
	if ref.Namespace == "" || ref.Name == "" {
		return SourceSummary{}, fmt.Errorf("source VM namespace and name are required")
	}
	vm, err := b.Client.Resource(gvrVM).Namespace(ref.Namespace).Get(ctx, ref.Name, metav1.GetOptions{})
	if err != nil {
		return SourceSummary{}, fmt.Errorf("get source VirtualMachine %s/%s: %w", ref.Namespace, ref.Name, err)
	}
	_, err = b.Client.Resource(gvrVMI).Namespace(ref.Namespace).Get(ctx, ref.Name, metav1.GetOptions{})
	vmiExists := err == nil
	if err != nil && !apierrors.IsNotFound(err) {
		return SourceSummary{}, fmt.Errorf("check active VMI %s/%s: %w", ref.Namespace, ref.Name, err)
	}
	return ValidateSource(vm, vmiExists, policy)
}

func (b *KubeVirtTemplateBackend) CreateTemplate(ctx context.Context, req CreateRequest) (TemplateState, error) {
	if b == nil || b.Client == nil {
		return TemplateState{}, fmt.Errorf("Kubernetes dynamic client is required")
	}
	if req.Namespace == "" || req.RequestName == "" || req.TemplateName == "" || req.SourceVMName == "" {
		return TemplateState{}, fmt.Errorf("namespace, requestName, templateName and sourceVMName are required")
	}
	caps, err := b.DiscoverCapabilities(ctx)
	if err != nil {
		return TemplateState{}, err
	}
	if !caps.NativeTemplatesReady() {
		return TemplateState{}, fmt.Errorf("native KubeVirt templates are not ready: Snapshot=%t Template=%t virtTemplateDeployment=%t", caps.SnapshotGate, caps.TemplateGate, caps.TemplateDeployment)
	}

	obj := &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "template.kubevirt.io/v1alpha1",
		"kind":       "VirtualMachineTemplateRequest",
		"metadata": map[string]interface{}{
			"name":      req.RequestName,
			"namespace": req.Namespace,
			"labels": map[string]interface{}{
				managedByLabel: managedByValue,
			},
		},
		"spec": map[string]interface{}{
			"virtualMachineRef": map[string]interface{}{
				"namespace": req.Namespace,
				"name":      req.SourceVMName,
			},
			"templateName": req.TemplateName,
		},
	}}
	created, err := b.Client.Resource(gvrRequest).Namespace(req.Namespace).Create(ctx, obj, metav1.CreateOptions{})
	if apierrors.IsAlreadyExists(err) {
		created, err = b.Client.Resource(gvrRequest).Namespace(req.Namespace).Get(ctx, req.RequestName, metav1.GetOptions{})
		if err == nil {
			if verifyErr := verifyExistingRequest(created, req); verifyErr != nil {
				return TemplateState{}, verifyErr
			}
		}
	}
	if err != nil {
		return TemplateState{}, fmt.Errorf("create VirtualMachineTemplateRequest %s/%s: %w", req.Namespace, req.RequestName, err)
	}
	return requestState(created), nil
}

func (b *KubeVirtTemplateBackend) VerifyTemplate(ctx context.Context, ref TemplateRef, requestName string) (TemplateState, error) {
	if b == nil || b.Client == nil {
		return TemplateState{}, fmt.Errorf("Kubernetes dynamic client is required")
	}
	if ref.Namespace == "" || ref.Name == "" || requestName == "" {
		return TemplateState{}, fmt.Errorf("template namespace/name and request name are required")
	}
	request, err := b.Client.Resource(gvrRequest).Namespace(ref.Namespace).Get(ctx, requestName, metav1.GetOptions{})
	if apierrors.IsNotFound(err) {
		return TemplateState{}, nil
	}
	if err != nil {
		return TemplateState{}, fmt.Errorf("get VirtualMachineTemplateRequest %s/%s: %w", ref.Namespace, requestName, err)
	}
	state := requestState(request)
	if !state.Ready {
		return state, nil
	}
	if state.TemplateName == "" {
		return TemplateState{}, fmt.Errorf("ready VirtualMachineTemplateRequest %s/%s has no status.templateRef.name", ref.Namespace, requestName)
	}
	if state.TemplateName != ref.Name {
		return TemplateState{}, fmt.Errorf("VirtualMachineTemplateRequest %s/%s created template %q, expected %q", ref.Namespace, requestName, state.TemplateName, ref.Name)
	}
	template, err := b.Client.Resource(gvrTemplate).Namespace(ref.Namespace).Get(ctx, ref.Name, metav1.GetOptions{})
	if apierrors.IsNotFound(err) {
		state.Ready = false
		return state, nil
	}
	if err != nil {
		return TemplateState{}, fmt.Errorf("get VirtualMachineTemplate %s/%s: %w", ref.Namespace, ref.Name, err)
	}
	if !conditionTrue(template, "Ready") {
		state.Ready = false
		return state, nil
	}
	return state, nil
}

// DeleteTemplate removes both native objects owned by one Cozystack template
// operation. Deletion is idempotent and intentionally does not touch snapshots
// or source VMDisk/PVC data by name; KubeVirt's template controller owns its
// generated storage lifecycle and reference protection is enforced above this
// adapter.
func (b *KubeVirtTemplateBackend) DeleteTemplate(ctx context.Context, ref TemplateRef, requestName string) error {
	if b == nil || b.Client == nil {
		return fmt.Errorf("Kubernetes dynamic client is required")
	}
	if ref.Namespace == "" || ref.Name == "" || requestName == "" {
		return fmt.Errorf("template namespace/name and request name are required")
	}
	if err := b.Client.Resource(gvrTemplate).Namespace(ref.Namespace).Delete(ctx, ref.Name, metav1.DeleteOptions{}); err != nil && !apierrors.IsNotFound(err) {
		return fmt.Errorf("delete VirtualMachineTemplate %s/%s: %w", ref.Namespace, ref.Name, err)
	}
	if err := b.Client.Resource(gvrRequest).Namespace(ref.Namespace).Delete(ctx, requestName, metav1.DeleteOptions{}); err != nil && !apierrors.IsNotFound(err) {
		return fmt.Errorf("delete VirtualMachineTemplateRequest %s/%s: %w", ref.Namespace, requestName, err)
	}
	return nil
}

func verifyExistingRequest(obj *unstructured.Unstructured, req CreateRequest) error {
	if obj == nil {
		return fmt.Errorf("existing template request is nil")
	}
	ns, _, _ := unstructured.NestedString(obj.Object, "spec", "virtualMachineRef", "namespace")
	name, _, _ := unstructured.NestedString(obj.Object, "spec", "virtualMachineRef", "name")
	templateName, _, _ := unstructured.NestedString(obj.Object, "spec", "templateName")
	if ns != req.Namespace || name != req.SourceVMName || templateName != req.TemplateName {
		return fmt.Errorf("existing VirtualMachineTemplateRequest %s/%s has different immutable source/template intent", req.Namespace, req.RequestName)
	}
	return nil
}

func requestState(obj *unstructured.Unstructured) TemplateState {
	if obj == nil {
		return TemplateState{}
	}
	templateName, _, _ := unstructured.NestedString(obj.Object, "status", "templateRef", "name")
	return TemplateState{RequestName: obj.GetName(), TemplateName: templateName, Ready: conditionTrue(obj, "Ready")}
}

func conditionTrue(obj *unstructured.Unstructured, conditionType string) bool {
	conditions, _, _ := unstructured.NestedSlice(obj.Object, "status", "conditions")
	for _, raw := range conditions {
		condition, ok := raw.(map[string]interface{})
		if !ok {
			continue
		}
		typeValue, _ := condition["type"].(string)
		status, _ := condition["status"].(string)
		if typeValue == conditionType && status == string(metav1.ConditionTrue) {
			return true
		}
	}
	return false
}

func FeatureGateNames(c Capabilities) []string {
	out := []string{}
	if c.SnapshotGate {
		out = append(out, "Snapshot")
	}
	if c.TemplateGate {
		out = append(out, "Template")
	}
	if c.TemplateDeployment {
		out = append(out, "virtTemplateDeployment")
	}
	sort.Strings(out)
	return out
}
