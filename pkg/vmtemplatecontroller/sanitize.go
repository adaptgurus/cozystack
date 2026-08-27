// SPDX-License-Identifier: Apache-2.0

package vmtemplatecontroller

import (
	"context"
	"fmt"

	"github.com/cozystack/cozystack/pkg/vmtemplate"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

var nativeTemplateGVK = schema.GroupVersionKind{Group: "template.kubevirt.io", Version: "v1alpha1", Kind: "VirtualMachineTemplate"}

const opticalSanitizedAnnotation = "virtualization.cozystack.io/optical-sanitized"

// SanitizingBackend decorates the native KubeVirt template backend. It never
// reports a template Ready while CD/DVD devices remain in the captured VM.
// This is intentionally a backend invariant rather than a dashboard option:
// reusable HCI templates must not replicate installer or VirtIO media into
// every future VM, and Convert must not retire its source before the sanitized
// definition has been durably persisted.
type SanitizingBackend struct {
	vmtemplate.Backend
	Client client.Client
}

func (b *SanitizingBackend) VerifyTemplate(ctx context.Context, ref vmtemplate.TemplateRef, requestName string) (vmtemplate.TemplateState, error) {
	if b == nil || b.Backend == nil || b.Client == nil {
		return vmtemplate.TemplateState{}, fmt.Errorf("sanitizing template backend and Kubernetes client are required")
	}
	state, err := b.Backend.VerifyTemplate(ctx, ref, requestName)
	if err != nil || !state.Ready {
		return state, err
	}

	tpl := &unstructured.Unstructured{}
	tpl.SetGroupVersionKind(nativeTemplateGVK)
	if err := b.Client.Get(ctx, client.ObjectKey{Namespace: ref.Namespace, Name: ref.Name}, tpl); err != nil {
		return vmtemplate.TemplateState{}, fmt.Errorf("get native VirtualMachineTemplate %s/%s for sanitation: %w", ref.Namespace, ref.Name, err)
	}
	optical, err := vmtemplate.TemplateOpticalVolumes(tpl)
	if err != nil {
		return vmtemplate.TemplateState{}, err
	}
	if len(optical) == 0 {
		return state, nil
	}

	base := tpl.DeepCopy()
	result, err := vmtemplate.StripOpticalVolumes(tpl, optical)
	if err != nil {
		return vmtemplate.TemplateState{}, err
	}
	if !result.Changed {
		return vmtemplate.TemplateState{}, fmt.Errorf("native template %s/%s reports optical devices %v but sanitation made no change", ref.Namespace, ref.Name, optical)
	}
	annotations := tpl.GetAnnotations()
	if annotations == nil {
		annotations = map[string]string{}
	}
	annotations[opticalSanitizedAnnotation] = "true"
	annotations["virtualization.cozystack.io/excluded-optical-count"] = fmt.Sprintf("%d", len(optical))
	tpl.SetAnnotations(annotations)
	if err := b.Client.Patch(ctx, tpl, client.MergeFrom(base)); err != nil {
		return vmtemplate.TemplateState{}, fmt.Errorf("persist sanitized VirtualMachineTemplate %s/%s: %w", ref.Namespace, ref.Name, err)
	}

	// Force a fresh read/reconcile before the transaction can finish. For
	// Convert this is the barrier that prevents source VM deletion before the
	// sanitized template is committed to the API server.
	state.Ready = false
	return state, nil
}
