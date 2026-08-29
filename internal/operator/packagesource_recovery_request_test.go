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
	"errors"
	"testing"

	sourcewatcherv1beta1 "github.com/fluxcd/source-watcher/api/v2/v1beta1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
)

func TestArtifactGeneratorSourceDiverged(t *testing.T) {
	_, ag, src, ea := readyRepairFixture(t)
	scheme := readyRepairScheme(t)

	t.Run("current persisted source is not divergent", func(t *testing.T) {
		c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ag.DeepCopy(), src.DeepCopy(), ea.DeepCopy()).Build()
		r := &PackageSourceReconciler{Client: c, Scheme: scheme}
		diverged, current, err := r.artifactGeneratorSourceDiverged(context.Background(), ag.DeepCopy())
		if err != nil || diverged || current != ag.Status.ObservedSourcesDigest {
			t.Fatalf("diverged=%v current=%q err=%v want false/%q", diverged, current, err, ag.Status.ObservedSourcesDigest)
		}
	})

	t.Run("stale ArtifactGenerator source is detected even if Ready is still true", func(t *testing.T) {
		stale := ag.DeepCopy()
		stale.Status.ObservedSourcesDigest = "sha256:old-source-state"
		stale.Status.Conditions = []metav1.Condition{{Type: "Ready", Status: metav1.ConditionTrue, Reason: "Succeeded", ObservedGeneration: stale.Generation}}
		c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(stale.DeepCopy(), src.DeepCopy(), ea.DeepCopy()).Build()
		r := &PackageSourceReconciler{Client: c, Scheme: scheme}
		diverged, current, err := r.artifactGeneratorSourceDiverged(context.Background(), stale)
		if err != nil || !diverged || current == "" {
			t.Fatalf("diverged=%v current=%q err=%v want true/non-empty", diverged, current, err)
		}
	})

	t.Run("fresh generator with no persisted source digest is owned by initial reconcile path", func(t *testing.T) {
		fresh := ag.DeepCopy()
		fresh.Status.ObservedSourcesDigest = ""
		c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(fresh.DeepCopy(), src.DeepCopy(), ea.DeepCopy()).Build()
		r := &PackageSourceReconciler{Client: c, Scheme: scheme}
		diverged, _, err := r.artifactGeneratorSourceDiverged(context.Background(), fresh)
		if err != nil || diverged {
			t.Fatalf("diverged=%v err=%v want false", diverged, err)
		}
	})
}

func TestRequestArtifactGeneratorRecovery_DoesNotTouchStatus(t *testing.T) {
	ag := newAG(map[string]string{"unrelated": "value"})
	ag.Status.Conditions = []metav1.Condition{{Type: "Ready", Status: metav1.ConditionUnknown, Reason: "Progressing", ObservedGeneration: 1}}
	beforeConditions := cloneConditions(ag.Status.Conditions)
	c := fake.NewClientBuilder().WithScheme(testScheme(t)).WithStatusSubresource(ag).WithObjects(ag).Build()
	r := &PackageSourceReconciler{Client: c, Scheme: testScheme(t)}

	if err := r.requestArtifactGeneratorRecovery(context.Background(), ag, referenceTime, 2); err != nil {
		t.Fatalf("requestArtifactGeneratorRecovery: %v", err)
	}
	ready := meta.FindStatusCondition(ag.Status.Conditions, "Ready")
	if ready == nil || ready.Status != metav1.ConditionUnknown || ready.Reason != "Progressing" {
		t.Fatalf("Ready changed in-memory: %+v", ready)
	}
	if len(ag.Status.Conditions) != len(beforeConditions) {
		t.Fatalf("condition count changed: %d want %d", len(ag.Status.Conditions), len(beforeConditions))
	}
	if ag.Annotations[annotationRecoveryAttempts] != "2" || ag.Annotations[annotationFluxRequestedAt] == "" || ag.Annotations[annotationLastRecoveryAt] == "" {
		t.Fatalf("recovery annotations missing: %v", ag.Annotations)
	}

	persisted := &sourcewatcherv1beta1.ArtifactGenerator{}
	if err := c.Get(context.Background(), client.ObjectKeyFromObject(ag), persisted); err != nil {
		t.Fatal(err)
	}
	persistedReady := meta.FindStatusCondition(persisted.Status.Conditions, "Ready")
	if persistedReady == nil || persistedReady.Status != metav1.ConditionUnknown || persistedReady.Reason != "Progressing" {
		t.Fatalf("persisted Ready mutated: %+v", persistedReady)
	}
}

func TestRequestArtifactGeneratorRecovery_MetadataFailureRollsBack(t *testing.T) {
	ag := newAG(map[string]string{"unrelated": "value"})
	base := fake.NewClientBuilder().WithScheme(testScheme(t)).WithObjects(ag).Build()
	failing := interceptor.NewClient(base, interceptor.Funcs{
		Patch: func(_ context.Context, _ client.WithWatch, _ client.Object, _ client.Patch, _ ...client.PatchOption) error {
			return errors.New("simulated metadata patch failure")
		},
	})
	r := &PackageSourceReconciler{Client: failing, Scheme: testScheme(t)}
	if err := r.requestArtifactGeneratorRecovery(context.Background(), ag, referenceTime, 3); err == nil {
		t.Fatal("requestArtifactGeneratorRecovery succeeded, want error")
	}
	if len(ag.Annotations) != 1 || ag.Annotations["unrelated"] != "value" {
		t.Fatalf("annotations not rolled back: %v", ag.Annotations)
	}
	if _, ok := ag.Annotations[annotationFluxRequestedAt]; ok {
		t.Fatalf("requestedAt leaked after failed patch: %v", ag.Annotations)
	}
}
