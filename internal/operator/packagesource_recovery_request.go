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
	"strconv"
	"time"

	sourcewatcherv1beta1 "github.com/fluxcd/source-watcher/api/v2/v1beta1"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// artifactGeneratorSourceDiverged compares the source state persisted by
// source-watcher with an independently recomputed hash of the currently
// published Flux source artifacts. This catches the important case where the
// upstream source changed but the ArtifactGenerator still reports Ready=True
// for the previous source revision and therefore would otherwise look healthy
// to a condition-only consumer.
//
// A fresh ArtifactGenerator with no observed digest is not called divergent;
// its normal initial reconciliation and grace-period path owns that state.
func (r *PackageSourceReconciler) artifactGeneratorSourceDiverged(
	ctx context.Context,
	ag *sourcewatcherv1beta1.ArtifactGenerator,
) (bool, string, error) {
	currentDigest, observable, err := r.currentArtifactGeneratorSourcesDigest(ctx, ag)
	if err != nil {
		return false, "", err
	}
	if !observable || currentDigest == "" || ag.Status.ObservedSourcesDigest == "" {
		return false, currentDigest, nil
	}
	return currentDigest != ag.Status.ObservedSourcesDigest, currentDigest, nil
}

// requestArtifactGeneratorRecovery enqueues source-watcher without mutating
// ArtifactGenerator.status. This is intentionally different from the old
// Ready=False force-drift workaround: source-watcher v2.1.0 already detects
// source, inventory, storage and ExternalArtifact drift on its own. Writing
// its Ready condition from Cozystack while a large artifact build is in flight
// can collide with source-watcher's SerialPatcher status writes and perpetuate
// fluxcd/pkg#934.
//
// The only writes here are metadata annotations:
//   - requestedAt triggers ReconcileRequestedPredicate;
//   - attempts / lastRecoveryAt persist the bounded backoff state.
//
// On metadata patch failure the caller object is restored to its exact prior
// annotations so the in-memory retry state cannot get ahead of the apiserver.
func (r *PackageSourceReconciler) requestArtifactGeneratorRecovery(
	ctx context.Context,
	ag *sourcewatcherv1beta1.ArtifactGenerator,
	now time.Time,
	nextAttempt int,
) error {
	base := ag.DeepCopy()
	priorAnnotations := cloneAnnotations(ag.Annotations)
	if ag.Annotations == nil {
		ag.Annotations = map[string]string{}
	}
	nowStr := now.UTC().Format(time.RFC3339Nano)
	ag.Annotations[annotationFluxRequestedAt] = nowStr
	ag.Annotations[annotationRecoveryAttempts] = strconv.Itoa(nextAttempt)
	ag.Annotations[annotationLastRecoveryAt] = nowStr
	if err := r.Patch(ctx, ag, client.MergeFrom(base)); err != nil {
		ag.Annotations = priorAnnotations
		return fmt.Errorf("metadata patch to request source-watcher recovery: %w", err)
	}
	return nil
}
