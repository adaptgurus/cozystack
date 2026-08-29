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
	"time"

	cozyv1alpha1 "github.com/cozystack/cozystack/api/v1alpha1"
	gotkmeta "github.com/fluxcd/pkg/apis/meta"
	sourcev1 "github.com/fluxcd/source-controller/api/v1"
	sourcewatcherv1beta1 "github.com/fluxcd/source-watcher/api/v2/v1beta1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func readyRepairScheme(t *testing.T) *runtime.Scheme {
	t.Helper()
	s := runtime.NewScheme()
	for name, add := range map[string]func(*runtime.Scheme) error{
		"cozystack":         cozyv1alpha1.AddToScheme,
		"source-watcher":    sourcewatcherv1beta1.AddToScheme,
		"source-controller": sourcev1.AddToScheme,
	} {
		if err := add(s); err != nil {
			t.Fatalf("%s AddToScheme: %v", name, err)
		}
	}
	return s
}

func readyRepairFixture(t *testing.T) (*cozyv1alpha1.PackageSource, *sourcewatcherv1beta1.ArtifactGenerator, *sourcev1.OCIRepository, *sourcev1.ExternalArtifact) {
	t.Helper()
	artifact := &gotkmeta.Artifact{
		Digest: "sha256:source-current", Revision: "sha256:release-current", URL: "http://source-controller/cozy-system/src/artifact.tar.gz",
		Metadata: map[string]string{sourcewatcherv1beta1.ArtifactOriginRevisionAnnotation: "git-current"},
	}
	src := &sourcev1.OCIRepository{
		ObjectMeta: metav1.ObjectMeta{Name: "src", Namespace: "cozy-system"},
		Status:     sourcev1.OCIRepositoryStatus{Artifact: artifact},
	}
	observed := map[string]sourcewatcherv1beta1.ObservedSource{
		"src": {Digest: artifact.Digest, Revision: artifact.Revision, URL: artifact.URL, OriginRevision: "git-current"},
	}
	ps := &cozyv1alpha1.PackageSource{
		ObjectMeta: metav1.ObjectMeta{Name: "example", Namespace: "cozy-system", Generation: 1},
		Spec:       cozyv1alpha1.PackageSourceSpec{SourceRef: &cozyv1alpha1.PackageSourceRef{Name: "src", Kind: sourcev1.OCIRepositoryKind, Namespace: "cozy-system"}},
	}
	ag := &sourcewatcherv1beta1.ArtifactGenerator{
		ObjectMeta: metav1.ObjectMeta{
			Name: "example", Namespace: "cozy-system", Generation: 1, UID: types.UID("ag-uid"),
			CreationTimestamp: metav1.NewTime(referenceTime.Add(-time.Hour)),
			Annotations: map[string]string{
				annotationRecoveryAttempts: "3",
				annotationLastRecoveryAt:   referenceTime.Add(-time.Minute).UTC().Format(time.RFC3339Nano),
			},
		},
		Spec: sourcewatcherv1beta1.ArtifactGeneratorSpec{
			Sources:         []sourcewatcherv1beta1.SourceReference{{Alias: "src", Name: "src", Namespace: "cozy-system", Kind: sourcev1.OCIRepositoryKind}},
			OutputArtifacts: []sourcewatcherv1beta1.OutputArtifact{{Name: "one"}},
		},
		Status: sourcewatcherv1beta1.ArtifactGeneratorStatus{
			ObservedSourcesDigest: sourcewatcherv1beta1.HashObservedSources(observed),
			Inventory:             []sourcewatcherv1beta1.ExternalArtifactReference{{Name: "one", Namespace: "cozy-system", Digest: "sha256:output-current", Filename: "output-current.tar.gz"}},
			Conditions:            []metav1.Condition{{Type: "Ready", Status: metav1.ConditionUnknown, Reason: "Progressing", ObservedGeneration: 1, LastTransitionTime: metav1.NewTime(referenceTime.Add(-2 * time.Minute))}},
		},
	}
	ea := &sourcev1.ExternalArtifact{
		ObjectMeta: metav1.ObjectMeta{Name: "one", Namespace: "cozy-system", Labels: map[string]string{sourcewatcherv1beta1.ArtifactGeneratorLabel: string(ag.UID)}},
		Spec:       sourcev1.ExternalArtifactSpec{SourceRef: &gotkmeta.NamespacedObjectKindReference{APIVersion: sourcewatcherv1beta1.GroupVersion.String(), Kind: sourcewatcherv1beta1.ArtifactGeneratorKind, Name: ag.Name, Namespace: ag.Namespace}},
		Status: sourcev1.ExternalArtifactStatus{
			Artifact:   &gotkmeta.Artifact{Digest: "sha256:output-current", Revision: "sha256:release-current", URL: "http://source-watcher/one.tar.gz"},
			Conditions: []metav1.Condition{{Type: "Ready", Status: metav1.ConditionTrue, Reason: "Succeeded", ObservedGeneration: 1}},
		},
	}
	return ps, ag, src, ea
}

func TestLostReadyRepairCandidate(t *testing.T) {
	ag := &sourcewatcherv1beta1.ArtifactGenerator{ObjectMeta: metav1.ObjectMeta{Generation: 2}}
	tests := []struct {
		name  string
		ready *metav1.Condition
		want  bool
	}{
		{"unknown current generation", &metav1.Condition{Status: metav1.ConditionUnknown, ObservedGeneration: 2}, true},
		{"our forced false current generation", &metav1.Condition{Status: metav1.ConditionFalse, Reason: reasonRecoveryForced, ObservedGeneration: 2}, true},
		{"real upstream false is never masked", &metav1.Condition{Status: metav1.ConditionFalse, Reason: "SourceFetchFailed", ObservedGeneration: 2}, false},
		{"true already healthy", &metav1.Condition{Status: metav1.ConditionTrue, Reason: "Succeeded", ObservedGeneration: 2}, false},
		{"stale generation", &metav1.Condition{Status: metav1.ConditionUnknown, ObservedGeneration: 1}, false},
		{"missing condition cannot prove spec generation", nil, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := lostReadyRepairCandidate(ag, tt.ready); got != tt.want {
				t.Errorf("candidate=%v want %v", got, tt.want)
			}
		})
	}
}

func TestProveArtifactGeneratorCurrentSuccess(t *testing.T) {
	ps, ag, src, ea := readyRepairFixture(t)
	_ = ps
	newClient := func(objects ...client.Object) client.Client {
		return fake.NewClientBuilder().WithScheme(readyRepairScheme(t)).WithObjects(objects...).Build()
	}
	t.Run("all current-source evidence matches", func(t *testing.T) {
		r := &PackageSourceReconciler{Client: newClient(ag.DeepCopy(), src.DeepCopy(), ea.DeepCopy()), Scheme: readyRepairScheme(t)}
		ok, err := r.proveArtifactGeneratorCurrentSuccess(context.Background(), ag.DeepCopy())
		if err != nil || !ok {
			t.Fatalf("proven=%v err=%v want true", ok, err)
		}
	})
	t.Run("stale observed source digest fails closed", func(t *testing.T) {
		bad := ag.DeepCopy()
		bad.Status.ObservedSourcesDigest = "sha256:stale"
		r := &PackageSourceReconciler{Client: newClient(bad.DeepCopy(), src.DeepCopy(), ea.DeepCopy()), Scheme: readyRepairScheme(t)}
		ok, err := r.proveArtifactGeneratorCurrentSuccess(context.Background(), bad)
		if err != nil || ok {
			t.Fatalf("proven=%v err=%v want false", ok, err)
		}
	})
	t.Run("incomplete inventory fails closed", func(t *testing.T) {
		bad := ag.DeepCopy()
		bad.Status.Inventory = nil
		r := &PackageSourceReconciler{Client: newClient(bad.DeepCopy(), src.DeepCopy(), ea.DeepCopy()), Scheme: readyRepairScheme(t)}
		ok, err := r.proveArtifactGeneratorCurrentSuccess(context.Background(), bad)
		if err != nil || ok {
			t.Fatalf("proven=%v err=%v want false", ok, err)
		}
	})
	t.Run("external artifact digest mismatch fails closed", func(t *testing.T) {
		badEA := ea.DeepCopy()
		badEA.Status.Artifact.Digest = "sha256:different"
		r := &PackageSourceReconciler{Client: newClient(ag.DeepCopy(), src.DeepCopy(), badEA), Scheme: readyRepairScheme(t)}
		ok, err := r.proveArtifactGeneratorCurrentSuccess(context.Background(), ag.DeepCopy())
		if err != nil || ok {
			t.Fatalf("proven=%v err=%v want false", ok, err)
		}
	})
	t.Run("external artifact not Ready fails closed", func(t *testing.T) {
		badEA := ea.DeepCopy()
		badEA.Status.Conditions[0].Status = metav1.ConditionFalse
		r := &PackageSourceReconciler{Client: newClient(ag.DeepCopy(), src.DeepCopy(), badEA), Scheme: readyRepairScheme(t)}
		ok, err := r.proveArtifactGeneratorCurrentSuccess(context.Background(), ag.DeepCopy())
		if err != nil || ok {
			t.Fatalf("proven=%v err=%v want false", ok, err)
		}
	})
}

func TestUpdateStatus_RepairsOnlyProvenLostReady(t *testing.T) {
	ps, ag, src, ea := readyRepairFixture(t)
	scheme := readyRepairScheme(t)
	c := fake.NewClientBuilder().WithScheme(scheme).WithStatusSubresource(ps, ag).WithObjects(ps, ag, src, ea).Build()
	r := &PackageSourceReconciler{Client: c, Scheme: scheme}
	res, err := r.updateStatus(context.Background(), ps, referenceTime)
	if err != nil {
		t.Fatalf("updateStatus: %v", err)
	}
	if res.RequeueAfter != 0 {
		t.Errorf("RequeueAfter=%v want 0 after proven repair", res.RequeueAfter)
	}
	persistedAG := &sourcewatcherv1beta1.ArtifactGenerator{}
	if err := c.Get(context.Background(), client.ObjectKeyFromObject(ag), persistedAG); err != nil {
		t.Fatal(err)
	}
	ready := meta.FindStatusCondition(persistedAG.Status.Conditions, "Ready")
	if ready == nil || ready.Status != metav1.ConditionTrue || ready.Reason != reasonRecoveredLostReady {
		t.Fatalf("AG Ready=%+v want True/%s", ready, reasonRecoveredLostReady)
	}
	if _, ok := persistedAG.Annotations[annotationRecoveryAttempts]; ok {
		t.Errorf("recovery tracking not cleared: %v", persistedAG.Annotations)
	}
	persistedPS := &cozyv1alpha1.PackageSource{}
	if err := c.Get(context.Background(), client.ObjectKeyFromObject(ps), persistedPS); err != nil {
		t.Fatal(err)
	}
	psReady := meta.FindStatusCondition(persistedPS.Status.Conditions, "Ready")
	if psReady == nil || psReady.Status != metav1.ConditionTrue || psReady.Reason != reasonRecoveredLostReady {
		t.Fatalf("PS Ready=%+v want True/%s", psReady, reasonRecoveredLostReady)
	}
}

func TestRepairLostReady_DoesNotMaskRealFailure(t *testing.T) {
	_, ag, src, ea := readyRepairFixture(t)
	ag.Status.Conditions[0] = metav1.Condition{Type: "Ready", Status: metav1.ConditionFalse, Reason: "SourceFetchFailed", ObservedGeneration: 1}
	scheme := readyRepairScheme(t)
	c := fake.NewClientBuilder().WithScheme(scheme).WithStatusSubresource(ag).WithObjects(ag, src, ea).Build()
	r := &PackageSourceReconciler{Client: c, Scheme: scheme}
	repaired, err := r.repairLostArtifactGeneratorReady(context.Background(), ag, meta.FindStatusCondition(ag.Status.Conditions, "Ready"), referenceTime)
	if err != nil || repaired {
		t.Fatalf("repaired=%v err=%v want false", repaired, err)
	}
}
