/*
Copyright 2025 The Cozystack Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package operator

import (
	"context"
	"fmt"
	"time"

	sourcev1 "github.com/fluxcd/source-controller/api/v1"
	sourcewatcherv1beta1 "github.com/fluxcd/source-watcher/api/v2/v1beta1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const reasonRecoveredLostReady = "RecoveredLostReady"

// The PackageSource controller only reads Flux source objects here. Keep
// these markers beside the recovery code so generated RBAC continues to
// cover every source kind supported by ArtifactGenerator.
// +kubebuilder:rbac:groups=source.toolkit.fluxcd.io,resources=ocirepositories,verbs=get;list;watch
// +kubebuilder:rbac:groups=source.toolkit.fluxcd.io,resources=gitrepositories,verbs=get;list;watch
// +kubebuilder:rbac:groups=source.toolkit.fluxcd.io,resources=buckets,verbs=get;list;watch
// +kubebuilder:rbac:groups=source.toolkit.fluxcd.io,resources=helmcharts,verbs=get;list;watch
// +kubebuilder:rbac:groups=source.toolkit.fluxcd.io,resources=externalartifacts,verbs=get;list;watch

// repairLostArtifactGeneratorReady repairs only the final Ready condition
// write lost to fluxcd/pkg#934. It does NOT infer success from inventory
// presence alone. Before writing Ready=True it proves that source-watcher
// has already completed the current reconciliation by independently
// reproducing its ObservedSourcesDigest calculation and validating every
// expected ExternalArtifact against the persisted inventory.
//
// This makes the repair fail closed:
//   - stale source digest: no repair
//   - incomplete/mismatched inventory: no repair
//   - ExternalArtifact missing/not Ready/digest mismatch: no repair
//   - genuine upstream Ready=False: no repair
//   - stale condition generation: no repair
//
// Only Ready=Unknown on the current generation, or our own synthetic
// Ready=False/SourceWatcherRecoveryForced marker, is eligible.
func (r *PackageSourceReconciler) repairLostArtifactGeneratorReady(
	ctx context.Context,
	ag *sourcewatcherv1beta1.ArtifactGenerator,
	ready *metav1.Condition,
	now time.Time,
) (bool, error) {
	if !lostReadyRepairCandidate(ag, ready) {
		return false, nil
	}

	proven, err := r.proveArtifactGeneratorCurrentSuccess(ctx, ag)
	if err != nil {
		return false, err
	}
	if !proven {
		return false, nil
	}

	base := ag.DeepCopy()
	priorConditions := cloneConditions(ag.Status.Conditions)
	meta.SetStatusCondition(&ag.Status.Conditions, metav1.Condition{
		Type:               "Ready",
		Status:             metav1.ConditionTrue,
		Reason:             reasonRecoveredLostReady,
		Message:            "source-watcher completed current-source artifact generation; cozystack repaired the final Ready=True condition lost to fluxcd/pkg#934",
		ObservedGeneration: ag.Generation,
		LastTransitionTime: metav1.NewTime(now),
	})
	if err := r.Status().Patch(ctx, ag, client.MergeFrom(base)); err != nil {
		ag.Status.Conditions = priorConditions
		return false, fmt.Errorf("patch recovered ArtifactGenerator Ready=True: %w", err)
	}
	return true, nil
}

func lostReadyRepairCandidate(ag *sourcewatcherv1beta1.ArtifactGenerator, ready *metav1.Condition) bool {
	if ready == nil || ready.ObservedGeneration != ag.Generation {
		return false
	}
	if ready.Status == metav1.ConditionUnknown {
		return true
	}
	return ready.Status == metav1.ConditionFalse && ready.Reason == reasonRecoveryForced
}

// proveArtifactGeneratorCurrentSuccess verifies the exact success state
// source-watcher v2.1.0 builds immediately before MarkTrue(Ready): current
// source hash persisted, complete fixed output inventory persisted, and
// every referenced ExternalArtifact persisted Ready with the same digest.
func (r *PackageSourceReconciler) proveArtifactGeneratorCurrentSuccess(ctx context.Context, ag *sourcewatcherv1beta1.ArtifactGenerator) (bool, error) {
	// PackageSource-generated ArtifactGenerators in the pinned v2.0.3 API
	// use fixed OutputArtifacts, which gives a one-to-one proof surface.
	if len(ag.Spec.OutputArtifacts) == 0 {
		return false, nil
	}
	if ag.Status.ObservedSourcesDigest == "" || len(ag.Status.Inventory) != len(ag.Spec.OutputArtifacts) {
		return false, nil
	}

	currentDigest, sourcesReady, err := r.currentArtifactGeneratorSourcesDigest(ctx, ag)
	if err != nil {
		return false, err
	}
	if !sourcesReady || currentDigest != ag.Status.ObservedSourcesDigest {
		return false, nil
	}

	expected := make(map[string]struct{}, len(ag.Spec.OutputArtifacts))
	for _, output := range ag.Spec.OutputArtifacts {
		if output.Name == "" {
			return false, nil
		}
		expected[output.Name] = struct{}{}
	}
	if len(expected) != len(ag.Spec.OutputArtifacts) {
		return false, nil
	}

	seen := make(map[string]struct{}, len(ag.Status.Inventory))
	for _, ref := range ag.Status.Inventory {
		if _, ok := expected[ref.Name]; !ok || ref.Namespace != ag.Namespace || ref.Digest == "" || ref.Filename == "" {
			return false, nil
		}
		if _, duplicate := seen[ref.Name]; duplicate {
			return false, nil
		}
		seen[ref.Name] = struct{}{}

		ea := &sourcev1.ExternalArtifact{}
		if err := r.Get(ctx, client.ObjectKey{Name: ref.Name, Namespace: ref.Namespace}, ea); err != nil {
			if apierrors.IsNotFound(err) {
				return false, nil
			}
			return false, fmt.Errorf("get ExternalArtifact %s/%s: %w", ref.Namespace, ref.Name, err)
		}
		if ea.Status.Artifact == nil || ea.Status.Artifact.Digest != ref.Digest || !meta.IsStatusConditionTrue(ea.Status.Conditions, "Ready") {
			return false, nil
		}
		if ea.Spec.SourceRef == nil || ea.Spec.SourceRef.Name != ag.Name || ea.Spec.SourceRef.Namespace != ag.Namespace ||
			ea.Spec.SourceRef.Kind != sourcewatcherv1beta1.ArtifactGeneratorKind || ea.Spec.SourceRef.APIVersion != sourcewatcherv1beta1.GroupVersion.String() {
			return false, nil
		}
		if ag.UID != "" && ea.Labels[sourcewatcherv1beta1.ArtifactGeneratorLabel] != string(ag.UID) {
			return false, nil
		}
	}
	return len(seen) == len(expected), nil
}

// currentArtifactGeneratorSourcesDigest intentionally mirrors
// source-watcher v2.1.0 observeSources() field-for-field and then calls
// the API package's HashObservedSources. Any difference in source URL,
// digest, revision, or origin revision makes the proof fail closed.
func (r *PackageSourceReconciler) currentArtifactGeneratorSourcesDigest(ctx context.Context, ag *sourcewatcherv1beta1.ArtifactGenerator) (string, bool, error) {
	observed := make(map[string]sourcewatcherv1beta1.ObservedSource, len(ag.Spec.Sources))
	for _, src := range ag.Spec.Sources {
		ns := src.Namespace
		if ns == "" {
			ns = ag.Namespace
		}
		key := client.ObjectKey{Name: src.Name, Namespace: ns}

		var source sourcev1.Source
		switch src.Kind {
		case sourcev1.OCIRepositoryKind:
			obj := &sourcev1.OCIRepository{}
			if err := r.Get(ctx, key, obj); err != nil {
				if apierrors.IsNotFound(err) {
					return "", false, nil
				}
				return "", false, fmt.Errorf("get OCIRepository %s: %w", key, err)
			}
			source = obj
		case sourcev1.GitRepositoryKind:
			obj := &sourcev1.GitRepository{}
			if err := r.Get(ctx, key, obj); err != nil {
				if apierrors.IsNotFound(err) {
					return "", false, nil
				}
				return "", false, fmt.Errorf("get GitRepository %s: %w", key, err)
			}
			source = obj
		case sourcev1.BucketKind:
			obj := &sourcev1.Bucket{}
			if err := r.Get(ctx, key, obj); err != nil {
				if apierrors.IsNotFound(err) {
					return "", false, nil
				}
				return "", false, fmt.Errorf("get Bucket %s: %w", key, err)
			}
			source = obj
		case sourcev1.HelmChartKind:
			obj := &sourcev1.HelmChart{}
			if err := r.Get(ctx, key, obj); err != nil {
				if apierrors.IsNotFound(err) {
					return "", false, nil
				}
				return "", false, fmt.Errorf("get HelmChart %s: %w", key, err)
			}
			source = obj
		case sourcev1.ExternalArtifactKind:
			obj := &sourcev1.ExternalArtifact{}
			if err := r.Get(ctx, key, obj); err != nil {
				if apierrors.IsNotFound(err) {
					return "", false, nil
				}
				return "", false, fmt.Errorf("get ExternalArtifact source %s: %w", key, err)
			}
			source = obj
		default:
			return "", false, nil
		}

		artifact := source.GetArtifact()
		if artifact == nil {
			return "", false, nil
		}
		state := sourcewatcherv1beta1.ObservedSource{
			Digest: artifact.Digest, Revision: artifact.Revision, URL: artifact.URL,
		}
		if origin, ok := artifact.Metadata[sourcewatcherv1beta1.ArtifactOriginRevisionAnnotation]; ok {
			state.OriginRevision = origin
		}
		observed[src.Alias] = state
	}
	if len(observed) != len(ag.Spec.Sources) {
		return "", false, nil
	}
	return sourcewatcherv1beta1.HashObservedSources(observed), true, nil
}
