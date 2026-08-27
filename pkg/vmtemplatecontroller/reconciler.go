// SPDX-License-Identifier: Apache-2.0

package vmtemplatecontroller

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/cozystack/cozystack/pkg/vmtemplate"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
)

var (
	OperationGVK = schema.GroupVersionKind{Group: "virtualization.cozystack.io", Version: "v1alpha1", Kind: "VMTemplateOperation"}
	vmInstanceGVK = schema.GroupVersionKind{Group: "apps.cozystack.io", Version: "v1alpha1", Kind: "VMInstance"}
	virtualMachineListGVK = schema.GroupVersionKind{Group: "kubevirt.io", Version: "v1", Kind: "VirtualMachineList"}
)

const (
	OperationFinalizer = "vmtemplateoperation.virtualization.cozystack.io/native-template-cleanup"
	globalOperationNamespace = "cozy-system"
	globalTemplateNamespace = "cozy-public"
	vmInstanceReleasePrefix = "vm-instance-"
)

type Reconciler struct {
	client.Client
	Backend      vmtemplate.Backend
	RequeueAfter time.Duration
}

type operationSpec struct {
	SourceVM              string
	SourceNamespace       string
	TemplateName          string
	Mode                  string
	Scope                 string
	ExcludeOpticalMedia   bool
	AllowSecretReferences bool
	RequireHalted         bool
}

func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	op := &unstructured.Unstructured{}
	op.SetGroupVersionKind(OperationGVK)
	if err := r.Get(ctx, req.NamespacedName, op); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}
	if r.Backend == nil {
		return ctrl.Result{}, fmt.Errorf("VM template backend is required")
	}

	if !op.GetDeletionTimestamp().IsZero() {
		return r.reconcileDelete(ctx, op)
	}
	if !controllerutil.ContainsFinalizer(op, OperationFinalizer) {
		base := op.DeepCopy()
		controllerutil.AddFinalizer(op, OperationFinalizer)
		if err := r.Patch(ctx, op, client.MergeFrom(base)); err != nil {
			return ctrl.Result{}, err
		}
		return ctrl.Result{Requeue: true}, nil
	}

	spec, err := parseSpec(op)
	if err != nil {
		_ = r.setPhase(ctx, op, "Failed", "InvalidSpec", err.Error(), false)
		return ctrl.Result{}, nil
	}
	sourceNamespace, targetNamespace, err := resolveNamespaces(op.GetNamespace(), spec)
	if err != nil {
		_ = r.setPhase(ctx, op, "Failed", "ScopeDenied", err.Error(), false)
		return ctrl.Result{}, nil
	}
	templateRef := vmtemplate.TemplateRef{Namespace: targetNamespace, Name: spec.TemplateName}
	requestName := op.GetName()

	// Always inspect the durable native transaction first. This is what makes a
	// restart after template Ready or after source deletion recover safely.
	state, err := r.Backend.VerifyTemplate(ctx, templateRef, requestName)
	if err != nil {
		_ = r.setPhase(ctx, op, "Failed", "TemplateVerifyFailed", err.Error(), false)
		return ctrl.Result{RequeueAfter: r.requeue()}, nil
	}
	if state.RequestName != "" {
		if !preflightCheckpointPresent(op) {
			_ = r.setPhase(ctx, op, "Failed", "MissingPreflightCheckpoint", "native template capture exists but the source UID/generation checkpoint is missing; refusing destructive continuation", false)
			return ctrl.Result{}, nil
		}
		if !state.Ready {
			_ = r.setPhase(ctx, op, "Capturing", "TemplateCaptureInProgress", "waiting for KubeVirt template capture to become Ready", false)
			return ctrl.Result{RequeueAfter: r.requeue()}, nil
		}
		return r.finishReadyTemplate(ctx, op, spec, sourceNamespace, templateRef, requestName)
	}

	// No native request exists. Preflight the authoritative Cozystack VMInstance
	// and live KubeVirt VM, then persist source identity before starting capture.
	sourceApp, err := r.getSourceVMInstance(ctx, sourceNamespace, spec.SourceVM)
	if err != nil {
		_ = r.setPhase(ctx, op, "Failed", "SourceVMUnavailable", err.Error(), false)
		return ctrl.Result{}, nil
	}
	kubeVirtVMName, err := r.resolveKubeVirtVMName(ctx, sourceNamespace, spec.SourceVM)
	if err != nil {
		_ = r.setPhase(ctx, op, "Failed", "SourceRuntimeUnavailable", err.Error(), false)
		return ctrl.Result{}, nil
	}
	policy := vmtemplate.SourcePolicy{
		RequireHalted:         spec.RequireHalted,
		ExcludeOpticalMedia:   spec.ExcludeOpticalMedia,
		AllowSecretReferences: spec.AllowSecretReferences,
	}
	summary, err := r.Backend.ValidateSource(ctx, vmtemplate.TemplateRef{Namespace: sourceNamespace, Name: kubeVirtVMName}, policy)
	if err != nil {
		_ = r.setPhase(ctx, op, "Failed", "PreflightRejected", err.Error(), false)
		return ctrl.Result{}, nil
	}
	if err := r.persistPreflightCheckpoint(ctx, op, sourceApp, sourceNamespace, kubeVirtVMName, summary); err != nil {
		return ctrl.Result{}, err
	}

	_, err = r.Backend.CreateTemplate(ctx, vmtemplate.CreateRequest{
		Namespace:       targetNamespace,
		SourceNamespace: sourceNamespace,
		RequestName:     requestName,
		TemplateName:    spec.TemplateName,
		SourceVMName:    kubeVirtVMName,
	})
	if err != nil {
		_ = r.setPhase(ctx, op, "Failed", "TemplateCreateFailed", err.Error(), false)
		return ctrl.Result{RequeueAfter: r.requeue()}, nil
	}
	if err := r.setPhase(ctx, op, "Capturing", "TemplateCaptureStarted", "native KubeVirt template capture request accepted", false); err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{RequeueAfter: r.requeue()}, nil
}

func (r *Reconciler) finishReadyTemplate(ctx context.Context, op *unstructured.Unstructured, spec operationSpec, sourceNamespace string, templateRef vmtemplate.TemplateRef, requestName string) (ctrl.Result, error) {
	if spec.Mode != "Convert" {
		if err := r.markReady(ctx, op, templateRef, requestName, false, "template copy is Ready"); err != nil {
			return ctrl.Result{}, err
		}
		return ctrl.Result{}, nil
	}

	source, err := r.getSourceVMInstance(ctx, sourceNamespace, spec.SourceVM)
	if apierrors.IsNotFound(err) {
		if err := r.markReady(ctx, op, templateRef, requestName, true, "template is Ready and source VMInstance retirement is complete"); err != nil {
			return ctrl.Result{}, err
		}
		return ctrl.Result{}, nil
	}
	if err != nil {
		_ = r.setPhase(ctx, op, "Failed", "SourceRecheckFailed", err.Error(), false)
		return ctrl.Result{RequeueAfter: r.requeue()}, nil
	}

	capturedUID, _, _ := unstructured.NestedString(op.Object, "status", "sourceUID")
	capturedGeneration, _, _ := unstructured.NestedInt64(op.Object, "status", "sourceGeneration")
	if capturedUID == "" || capturedGeneration == 0 {
		_ = r.setPhase(ctx, op, "Failed", "MissingPreflightCheckpoint", "source identity checkpoint is incomplete; refusing source deletion", false)
		return ctrl.Result{}, nil
	}
	if string(source.GetUID()) != capturedUID || source.GetGeneration() != capturedGeneration {
		_ = r.setPhase(ctx, op, "Failed", "SourceChangedAfterCapture", fmt.Sprintf("source VMInstance identity/generation changed after template capture (captured uid=%s generation=%d, current uid=%s generation=%d); refusing deletion", capturedUID, capturedGeneration, source.GetUID(), source.GetGeneration()), false)
		return ctrl.Result{}, nil
	}

	uid := source.GetUID()
	resourceVersion := source.GetResourceVersion()
	if err := r.Delete(ctx, source, client.Preconditions{UID: &uid, ResourceVersion: &resourceVersion}); err != nil && !apierrors.IsNotFound(err) {
		_ = r.setPhase(ctx, op, "Failed", "SourceRetireFailed", err.Error(), false)
		return ctrl.Result{RequeueAfter: r.requeue()}, nil
	}
	if err := r.setPhase(ctx, op, "Converting", "SourceRetirementStarted", "template is Ready; waiting for source VMInstance deletion to complete", false); err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{RequeueAfter: r.requeue()}, nil
}

func (r *Reconciler) reconcileDelete(ctx context.Context, op *unstructured.Unstructured) (ctrl.Result, error) {
	if !controllerutil.ContainsFinalizer(op, OperationFinalizer) {
		return ctrl.Result{}, nil
	}
	spec, err := parseSpec(op)
	if err != nil {
		// An invalid object should normally have been rejected by the CRD. On
		// deletion, derive only safe names and never delete anything guessed from
		// malformed fields.
		return ctrl.Result{}, fmt.Errorf("cannot safely finalize invalid VMTemplateOperation %s/%s: %w", op.GetNamespace(), op.GetName(), err)
	}
	_, targetNamespace, err := resolveNamespaces(op.GetNamespace(), spec)
	if err != nil {
		return ctrl.Result{}, err
	}
	_ = r.setPhase(ctx, op, "Deleting", "DeletingTemplate", "removing controller-owned native template resources", false)
	if err := r.Backend.DeleteTemplate(ctx, vmtemplate.TemplateRef{Namespace: targetNamespace, Name: spec.TemplateName}, op.GetName()); err != nil {
		return ctrl.Result{RequeueAfter: r.requeue()}, err
	}
	base := op.DeepCopy()
	controllerutil.RemoveFinalizer(op, OperationFinalizer)
	if err := r.Patch(ctx, op, client.MergeFrom(base)); err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{}, nil
}

func (r *Reconciler) getSourceVMInstance(ctx context.Context, namespace, name string) (*unstructured.Unstructured, error) {
	obj := &unstructured.Unstructured{}
	obj.SetGroupVersionKind(vmInstanceGVK)
	if err := r.Get(ctx, client.ObjectKey{Namespace: namespace, Name: name}, obj); err != nil {
		return nil, err
	}
	return obj, nil
}

func (r *Reconciler) resolveKubeVirtVMName(ctx context.Context, namespace, sourceVM string) (string, error) {
	releaseName := vmInstanceReleasePrefix + sourceVM
	list := &unstructured.UnstructuredList{}
	list.SetGroupVersionKind(virtualMachineListGVK)
	if err := r.List(ctx, list, client.InNamespace(namespace), client.MatchingLabels{"app.kubernetes.io/instance": releaseName}); err != nil {
		return "", fmt.Errorf("list KubeVirt VirtualMachines for VMInstance %s/%s: %w", namespace, sourceVM, err)
	}
	if len(list.Items) != 1 {
		return "", fmt.Errorf("VMInstance %s/%s must resolve to exactly one KubeVirt VirtualMachine by release label %q, found %d", namespace, sourceVM, releaseName, len(list.Items))
	}
	return list.Items[0].GetName(), nil
}

func parseSpec(op *unstructured.Unstructured) (operationSpec, error) {
	if op == nil {
		return operationSpec{}, fmt.Errorf("VMTemplateOperation is required")
	}
	sourceVM, _, _ := unstructured.NestedString(op.Object, "spec", "sourceVM")
	sourceNamespace, _, _ := unstructured.NestedString(op.Object, "spec", "sourceNamespace")
	templateName, _, _ := unstructured.NestedString(op.Object, "spec", "templateName")
	mode, foundMode, _ := unstructured.NestedString(op.Object, "spec", "mode")
	if !foundMode || mode == "" {
		mode = "Copy"
	}
	scope, foundScope, _ := unstructured.NestedString(op.Object, "spec", "scope")
	if !foundScope || scope == "" {
		scope = "Tenant"
	}
	excludeOptical, foundExclude, _ := unstructured.NestedBool(op.Object, "spec", "excludeOpticalMedia")
	if !foundExclude {
		excludeOptical = true
	}
	allowSecrets, foundSecrets, _ := unstructured.NestedBool(op.Object, "spec", "allowSecretReferences")
	if !foundSecrets {
		allowSecrets = true
	}
	requireHalted, foundHalted, _ := unstructured.NestedBool(op.Object, "spec", "requireHalted")
	if !foundHalted {
		requireHalted = true
	}
	if sourceVM == "" || templateName == "" {
		return operationSpec{}, fmt.Errorf("sourceVM and templateName are required")
	}
	if mode != "Copy" && mode != "Convert" {
		return operationSpec{}, fmt.Errorf("unsupported mode %q", mode)
	}
	if scope != "Tenant" && scope != "Global" {
		return operationSpec{}, fmt.Errorf("unsupported scope %q", scope)
	}
	return operationSpec{SourceVM: sourceVM, SourceNamespace: sourceNamespace, TemplateName: templateName, Mode: mode, Scope: scope, ExcludeOpticalMedia: excludeOptical, AllowSecretReferences: allowSecrets, RequireHalted: requireHalted}, nil
}

func resolveNamespaces(operationNamespace string, spec operationSpec) (sourceNamespace, targetNamespace string, err error) {
	if spec.Scope == "Tenant" {
		if spec.SourceNamespace != "" {
			return "", "", fmt.Errorf("Tenant template operations cannot select a different source namespace")
		}
		return operationNamespace, operationNamespace, nil
	}
	if operationNamespace != globalOperationNamespace {
		return "", "", fmt.Errorf("Global template promotion operations are accepted only in %s", globalOperationNamespace)
	}
	if spec.SourceNamespace == "" {
		return "", "", fmt.Errorf("Global template promotion requires sourceNamespace")
	}
	if spec.Mode == "Convert" {
		return "", "", fmt.Errorf("Global template promotion is copy-only")
	}
	if spec.AllowSecretReferences {
		return "", "", fmt.Errorf("Global template promotion cannot retain secret references")
	}
	return spec.SourceNamespace, globalTemplateNamespace, nil
}

func preflightCheckpointPresent(op *unstructured.Unstructured) bool {
	uid, _, _ := unstructured.NestedString(op.Object, "status", "sourceUID")
	generation, _, _ := unstructured.NestedInt64(op.Object, "status", "sourceGeneration")
	return uid != "" && generation > 0
}

func (r *Reconciler) persistPreflightCheckpoint(ctx context.Context, op, source *unstructured.Unstructured, sourceNamespace, kubeVirtVMName string, summary vmtemplate.SourceSummary) error {
	base := op.DeepCopy()
	status, _, _ := unstructured.NestedMap(op.Object, "status")
	if status == nil {
		status = map[string]interface{}{}
	}
	status["observedGeneration"] = op.GetGeneration()
	status["phase"] = "Preflight"
	status["requestRef"] = op.GetName()
	status["templateRef"], _, _ = unstructured.NestedString(op.Object, "spec", "templateName")
	status["sourceVMRef"] = sourceNamespace + "/" + kubeVirtVMName
	status["sourceUID"] = string(source.GetUID())
	status["sourceGeneration"] = source.GetGeneration()
	status["persistentVolumes"] = stringInterfaces(summary.PersistentVolumes)
	status["excludedOpticalVolumes"] = stringInterfaces(summary.OpticalVolumes)
	status["converted"] = false
	status["message"] = "source identity and storage preflight persisted before native template capture"
	status["conditions"] = []interface{}{conditionMap(op.GetGeneration(), metav1.ConditionFalse, "PreflightComplete", "source preflight passed; native template capture has not completed")}
	if err := unstructured.SetNestedMap(op.Object, status, "status"); err != nil {
		return err
	}
	return r.Status().Patch(ctx, op, client.MergeFrom(base))
}

func (r *Reconciler) markReady(ctx context.Context, op *unstructured.Unstructured, templateRef vmtemplate.TemplateRef, requestName string, converted bool, message string) error {
	base := op.DeepCopy()
	status, _, _ := unstructured.NestedMap(op.Object, "status")
	if status == nil {
		status = map[string]interface{}{}
	}
	status["observedGeneration"] = op.GetGeneration()
	status["phase"] = "Ready"
	status["requestRef"] = requestName
	status["templateRef"] = templateRef.Namespace + "/" + templateRef.Name
	status["converted"] = converted
	status["message"] = truncate(message, 2048)
	status["lastVerifiedAt"] = time.Now().UTC().Format(time.RFC3339)
	status["conditions"] = []interface{}{conditionMap(op.GetGeneration(), metav1.ConditionTrue, "TemplateReady", truncate(message, 1024))}
	if err := unstructured.SetNestedMap(op.Object, status, "status"); err != nil {
		return err
	}
	return r.Status().Patch(ctx, op, client.MergeFrom(base))
}

func (r *Reconciler) setPhase(ctx context.Context, op *unstructured.Unstructured, phase, reason, message string, ready bool) error {
	base := op.DeepCopy()
	status, _, _ := unstructured.NestedMap(op.Object, "status")
	if status == nil {
		status = map[string]interface{}{}
	}
	status["observedGeneration"] = op.GetGeneration()
	status["phase"] = phase
	status["message"] = truncate(message, 2048)
	conditionStatus := metav1.ConditionFalse
	if ready {
		conditionStatus = metav1.ConditionTrue
	}
	status["conditions"] = []interface{}{conditionMap(op.GetGeneration(), conditionStatus, reason, truncate(message, 1024))}
	if err := unstructured.SetNestedMap(op.Object, status, "status"); err != nil {
		return err
	}
	return r.Status().Patch(ctx, op, client.MergeFrom(base))
}

func conditionMap(generation int64, status metav1.ConditionStatus, reason, message string) map[string]interface{} {
	return map[string]interface{}{
		"type":               "Ready",
		"status":             string(status),
		"observedGeneration": generation,
		"lastTransitionTime": time.Now().UTC().Format(time.RFC3339),
		"reason":             truncate(reason, 128),
		"message":            truncate(message, 1024),
	}
}

func stringInterfaces(values []string) []interface{} {
	out := make([]interface{}, 0, len(values))
	for _, value := range values {
		out = append(out, value)
	}
	return out
}

func truncate(value string, max int) string {
	value = strings.TrimSpace(value)
	if len(value) <= max {
		return value
	}
	return value[:max]
}

func (r *Reconciler) requeue() time.Duration {
	if r.RequeueAfter <= 0 {
		return 5 * time.Second
	}
	return r.RequeueAfter
}
