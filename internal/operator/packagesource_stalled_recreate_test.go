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
	"testing"

	cozyv1alpha1 "github.com/cozystack/cozystack/api/v1alpha1"
	gotkmeta "github.com/fluxcd/pkg/apis/meta"
	sourcev1 "github.com/fluxcd/source-controller/api/v1"
	sourcewatcherv1beta1 "github.com/fluxcd/source-watcher/api/v2/v1beta1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func TestShouldRecreateStalledArtifactGenerator(t *testing.T) {
	tests := []struct {
		name       string
		current    string
		observed   string
		recreated  string
		observable bool
		want       bool
	}{
		{"new current source gets one recovery", "sha256:new", "sha256:old", "", true, true},
		{"same source cannot recreate twice", "sha256:new", "sha256:old", "sha256:new", true, false},
		{"already-current generator is never recreated", "sha256:new", "sha256:new", "", true, false},
		{"unobservable source fails closed", "sha256:new", "sha256:old", "", false, false},
		{"missing current digest fails closed", "", "sha256:old", "", true, false},
		{"missing persisted digest fails closed", "sha256:new", "", "", true, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := shouldRecreateStalledArtifactGenerator(tt.current, tt.observed, tt.recreated, tt.observable); got != tt.want {
				t.Fatalf("got %v want %v", got, tt.want)
			}
		})
	}
}

func stalledRecreateFixture(t *testing.T) (*cozyv1alpha1.PackageSource, *sourcewatcherv1beta1.ArtifactGenerator, *sourcev1.OCIRepository, string) {
	t.Helper()
	artifact := &gotkmeta.Artifact{
		Digest:   "sha256:source-new",
		Revision: "sha256:release-new",
		URL:      "http://source-controller/cozy-system/src/artifact.tar.gz",
	}
	src := &sourcev1.OCIRepository{
		ObjectMeta: metav1.ObjectMeta{Name: "src", Namespace: "cozy-system"},
		Status:     sourcev1.OCIRepositoryStatus{Artifact: artifact},
	}
	observed := map[string]sourcewatcherv1beta1.ObservedSource{
		"src": {Digest: artifact.Digest, Revision: artifact.Revision, URL: artifact.URL},
	}
	currentDigest := sourcewatcherv1beta1.HashObservedSources(observed)
	ps := &cozyv1alpha1.PackageSource{
		ObjectMeta: metav1.ObjectMeta{Name: "example", Namespace: "cozy-system", Generation: 1},
		Spec: cozyv1alpha1.PackageSourceSpec{SourceRef: &cozyv1alpha1.PackageSourceRef{
			Name: "src", Kind: sourcev1.OCIRepositoryKind, Namespace: "cozy-system",
		}},
	}
	ag := &sourcewatcherv1beta1.ArtifactGenerator{
		ObjectMeta: metav1.ObjectMeta{Name: "example", Namespace: "cozy-system", Generation: 1},
		Spec: sourcewatcherv1beta1.ArtifactGeneratorSpec{
			Sources:         []sourcewatcherv1beta1.SourceReference{{Alias: "src", Name: "src", Namespace: "cozy-system", Kind: sourcev1.OCIRepositoryKind}},
			OutputArtifacts: []sourcewatcherv1beta1.OutputArtifact{{Name: "one"}},
		},
		Status: sourcewatcherv1beta1.ArtifactGeneratorStatus{
			ObservedSourcesDigest: "sha256:stale-observed",
			Inventory: []sourcewatcherv1beta1.ExternalArtifactReference{{
				Name: "one", Namespace: "cozy-system", Digest: "sha256:old-output", Filename: "old.tar.gz",
			}},
			Conditions: []metav1.Condition{{Type: "Ready", Status: metav1.ConditionUnknown, Reason: "Progressing", ObservedGeneration: 1}},
		},
	}
	return ps, ag, src, currentDigest
}

func TestMaybeRecreateStalledArtifactGenerator_OneShotForCurrentSource(t *testing.T) {
	ps, ag, src, currentDigest := stalledRecreateFixture(t)
	scheme := readyRepairScheme(t)
	c := fake.NewClientBuilder().WithScheme(scheme).WithStatusSubresource(ps, ag).WithObjects(ps, ag, src).Build()
	r := &PackageSourceReconciler{Client: c, Scheme: scheme}

	recreated, err := r.maybeRecreateStalledArtifactGenerator(context.Background(), ps, ag, referenceTime)
	if err != nil || !recreated {
		t.Fatalf("recreated=%v err=%v want true", recreated, err)
	}

	persistedPS := &cozyv1alpha1.PackageSource{}
	if err := c.Get(context.Background(), client.ObjectKeyFromObject(ps), persistedPS); err != nil {
		t.Fatal(err)
	}
	if got := persistedPS.Annotations[annotationRecreatedForSourceDigest]; got != currentDigest {
		t.Fatalf("recreate marker=%q want %q", got, currentDigest)
	}
	ready := meta.FindStatusCondition(persistedPS.Status.Conditions, "Ready")
	if ready == nil || ready.Status != metav1.ConditionUnknown || ready.Reason != reasonRecreatingArtifactGenerator {
		t.Fatalf("PackageSource Ready=%+v want Unknown/%s", ready, reasonRecreatingArtifactGenerator)
	}

	persistedAG := &sourcewatcherv1beta1.ArtifactGenerator{}
	if err := c.Get(context.Background(), client.ObjectKeyFromObject(ag), persistedAG); !apierrors.IsNotFound(err) {
		t.Fatalf("stale ArtifactGenerator still exists or unexpected error: %v", err)
	}
}

func TestMaybeRecreateStalledArtifactGenerator_DoesNotRepeatSameSource(t *testing.T) {
	ps, ag, src, currentDigest := stalledRecreateFixture(t)
	ps.Annotations = map[string]string{annotationRecreatedForSourceDigest: currentDigest}
	scheme := readyRepairScheme(t)
	c := fake.NewClientBuilder().WithScheme(scheme).WithStatusSubresource(ps, ag).WithObjects(ps, ag, src).Build()
	r := &PackageSourceReconciler{Client: c, Scheme: scheme}

	recreated, err := r.maybeRecreateStalledArtifactGenerator(context.Background(), ps, ag, referenceTime)
	if err != nil || recreated {
		t.Fatalf("recreated=%v err=%v want false", recreated, err)
	}
	persistedAG := &sourcewatcherv1beta1.ArtifactGenerator{}
	if err := c.Get(context.Background(), client.ObjectKeyFromObject(ag), persistedAG); err != nil {
		t.Fatalf("ArtifactGenerator should remain: %v", err)
	}
}
