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

	cozyv1alpha1 "github.com/cozystack/cozystack/api/v1alpha1"
	sourcewatcherv1beta1 "github.com/fluxcd/source-watcher/api/v2/v1beta1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	annotationRecreatedForSourceDigest = "cozystack.io/source-watcher-recreated-for-source-digest"
	annotationLastGeneratorRecreateAt  = "cozystack.io/source-watcher-last-generator-recreate-at"
	reasonRecreatingArtifactGenerator  = "RecreatingArtifactGenerator"
)

// shouldRecreateStalledArtifactGenerator is intentionally narrow. A delete /
// recreate is allowed only when the source-watcher input can be independently
// observed and its current hash differs from the hash persisted on the stuck
// ArtifactGenerator. If the hashes match, the generator has consumed the
// current source already and a mismatch in inventory / ExternalArtifacts is a
// genuine failure that must remain fail-closed rather than be hidden by a
// destructive-looking recovery action.
//
// The PackageSource annotation makes the action one-shot per exact current
// source hash. A later package revision gets a different hash and therefore a
// fresh one-shot recovery budget without any unbounded retry counter.
func shouldRecreateStalledArtifactGenerator(currentDigest, observedDigest, recreatedForDigest string, sourceObservable bool) bool {
	if !sourceObservable || currentDigest == "" || observedDigest == "" {
		return false
	}
	if currentDigest == observedDigest {
		return false
	}
	return recreatedForDigest != currentDigest
}

// maybeRecreateStalledArtifactGenerator performs the final bounded self-heal
// after the normal force-drift budget has been exhausted. It addresses the
// harder failure mode where source-watcher never consumes a newly Ready Flux
// source at all, leaving ArtifactGenerator.status.observedSourcesDigest stale.
//
// Safety properties:
//   - only PackageSource-owned generated state is recreated;
//   - the current source hash is recomputed independently from Flux source
//     artifacts before any mutation;
//   - an already-current ArtifactGenerator is never recreated;
//   - at most one recreate occurs for a given current source hash;
//   - real output / ExternalArtifact mismatches remain fail-closed;
//   - the PackageSource reports Unknown while the generated object is being
//     recreated, never a synthetic Ready=True.
func (r *PackageSourceReconciler) maybeRecreateStalledArtifactGenerator(
	ctx context.Context,
	packageSource *cozyv1alpha1.PackageSource,
	ag *sourcewatcherv1beta1.ArtifactGenerator,
	now time.Time,
) (bool, error) {
	currentDigest, sourceObservable, err := r.currentArtifactGeneratorSourcesDigest(ctx, ag)
	if err != nil {
		return false, fmt.Errorf("observe current ArtifactGenerator sources before recreate: %w", err)
	}

	recreatedFor := ""
	if packageSource.Annotations != nil {
		recreatedFor = packageSource.Annotations[annotationRecreatedForSourceDigest]
	}
	if !shouldRecreateStalledArtifactGenerator(currentDigest, ag.Status.ObservedSourcesDigest, recreatedFor, sourceObservable) {
		return false, nil
	}

	meta.SetStatusCondition(&packageSource.Status.Conditions, metav1.Condition{
		Type:               "Ready",
		Status:             metav1.ConditionUnknown,
		Reason:             reasonRecreatingArtifactGenerator,
		Message:            fmt.Sprintf("source-watcher did not consume current source after bounded recovery; recreating generated ArtifactGenerator once for source digest %s", currentDigest),
		ObservedGeneration: packageSource.Generation,
		LastTransitionTime: metav1.NewTime(now),
	})
	if err := r.Status().Update(ctx, packageSource); err != nil {
		return false, fmt.Errorf("mark PackageSource awaiting ArtifactGenerator recreate: %w", err)
	}

	annotationBase := packageSource.DeepCopy()
	if packageSource.Annotations == nil {
		packageSource.Annotations = map[string]string{}
	}
	packageSource.Annotations[annotationRecreatedForSourceDigest] = currentDigest
	packageSource.Annotations[annotationLastGeneratorRecreateAt] = now.UTC().Format(time.RFC3339Nano)
	if err := r.Patch(ctx, packageSource, client.MergeFrom(annotationBase)); err != nil {
		return false, fmt.Errorf("record bounded ArtifactGenerator recreate marker: %w", err)
	}

	if err := r.Delete(ctx, ag); err != nil && !apierrors.IsNotFound(err) {
		// Roll the one-shot marker back if deletion did not happen. This keeps a
		// transient API failure from permanently consuming the recovery budget.
		rollbackBase := packageSource.DeepCopy()
		packageSource.Annotations = cloneAnnotations(annotationBase.Annotations)
		if rollbackErr := r.Patch(ctx, packageSource, client.MergeFrom(rollbackBase)); rollbackErr != nil {
			return false, fmt.Errorf("delete stale ArtifactGenerator: %v; rollback recreate marker: %w", err, rollbackErr)
		}
		return false, fmt.Errorf("delete stale ArtifactGenerator: %w", err)
	}

	return true, nil
}
