// SPDX-License-Identifier: Apache-2.0

package vmtemplatecontroller

import (
	"context"
	"crypto/sha256"
	"fmt"
	"sort"
	"strings"

	"github.com/cozystack/cozystack/pkg/vmtemplate"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

var nativeTemplateGVK = schema.GroupVersionKind{Group: "template.kubevirt.io", Version: "v1alpha1", Kind: "VirtualMachineTemplate"}

const opticalSanitizedAnnotation = "virtualization.cozystack.io/optical-sanitized"

// ensureOpticalMediaSanitized durably removes preflight-identified CD/DVD
// attachments from the native template before Copy is reported Ready or
// Convert is allowed to retire the source VMInstance. It returns true only
// after a fresh Kubernetes read proves the expected sanitation fingerprint is
// already persisted and no excluded attachments remain.
func (r *Reconciler) ensureOpticalMediaSanitized(ctx context.Context, op *unstructured.Unstructured, ref vmtemplate.TemplateRef) (bool, error) {
	excluded, found, err := unstructured.NestedStringSlice(op.Object, "status", "excludedOpticalVolumes")
	if err != nil {
		return false, fmt.Errorf("read excluded optical media checkpoint: %w", err)
	}
	if !found || len(excluded) == 0 {
		return true, nil
	}
	sort.Strings(excluded)
	fingerprint := fmt.Sprintf("%x", sha256.Sum256([]byte(strings.Join(excluded, "\x00"))))

	tpl := &unstructured.Unstructured{}
	tpl.SetGroupVersionKind(nativeTemplateGVK)
	if err := r.Get(ctx, client.ObjectKey{Namespace: ref.Namespace, Name: ref.Name}, tpl); err != nil {
		return false, fmt.Errorf("get native VirtualMachineTemplate %s/%s for sanitation: %w", ref.Namespace, ref.Name, err)
	}

	// Even when the annotation is already present, prove the spec remains
	// sanitized. This protects against manual/external mutation after capture.
	probe := tpl.DeepCopy()
	probeResult, err := vmtemplate.StripOpticalVolumes(probe, excluded)
	if err != nil {
		return false, err
	}
	if tpl.GetAnnotations()[opticalSanitizedAnnotation] == fingerprint && !probeResult.Changed {
		return true, nil
	}

	base := tpl.DeepCopy()
	result, err := vmtemplate.StripOpticalVolumes(tpl, excluded)
	if err != nil {
		return false, err
	}
	annotations := tpl.GetAnnotations()
	if annotations == nil {
		annotations = map[string]string{}
	}
	annotations[opticalSanitizedAnnotation] = fingerprint
	annotations["virtualization.cozystack.io/excluded-optical-count"] = fmt.Sprintf("%d", len(excluded))
	tpl.SetAnnotations(annotations)
	if err := r.Patch(ctx, tpl, client.MergeFrom(base)); err != nil {
		return false, fmt.Errorf("persist sanitized VirtualMachineTemplate %s/%s: %w", ref.Namespace, ref.Name, err)
	}
	// Re-read on the next reconcile before allowing a source VM deletion.
	_ = result
	return false, nil
}
