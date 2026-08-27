// SPDX-License-Identifier: Apache-2.0

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestValidateKubernetesNodeForTalosMutation(t *testing.T) {
	readyWorker := &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{Name: "worker-1", Labels: map[string]string{"cozystack.io/virtualization": "true"}},
		Status: corev1.NodeStatus{Conditions: []corev1.NodeCondition{{Type: corev1.NodeReady, Status: corev1.ConditionTrue}}},
	}
	if err := validateKubernetesNodeForTalosMutation(readyWorker, false); err != nil {
		t.Fatalf("ready worker rejected: %v", err)
	}

	notReady := readyWorker.DeepCopy()
	notReady.Name = "worker-not-ready"
	notReady.Status.Conditions[0].Status = corev1.ConditionFalse
	if err := validateKubernetesNodeForTalosMutation(notReady, false); err == nil || !strings.Contains(err.Error(), "not Ready") {
		t.Fatalf("expected NotReady node rejection, got %v", err)
	}

	controlPlane := readyWorker.DeepCopy()
	controlPlane.Name = "control-1"
	controlPlane.Labels["node-role.kubernetes.io/control-plane"] = ""
	if err := validateKubernetesNodeForTalosMutation(controlPlane, false); err == nil || !strings.Contains(err.Error(), "disabled by default") {
		t.Fatalf("expected control-plane default rejection, got %v", err)
	}
	if err := validateKubernetesNodeForTalosMutation(controlPlane, true); err != nil {
		t.Fatalf("explicit control-plane opt-in rejected: %v", err)
	}
}

func TestTalosConfigReadyz(t *testing.T) {
	t.Run("missing", func(t *testing.T) {
		if err := talosConfigReadyz(filepath.Join(t.TempDir(), "missing"))(nil); err == nil {
			t.Fatal("expected missing Talos client configuration to fail readiness")
		}
	})

	t.Run("empty", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "talosconfig")
		if err := os.WriteFile(path, nil, 0o600); err != nil {
			t.Fatalf("write empty Talos client configuration: %v", err)
		}
		if err := talosConfigReadyz(path)(nil); err == nil {
			t.Fatal("expected empty Talos client configuration to fail readiness")
		}
	})

	t.Run("readable", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "talosconfig")
		if err := os.WriteFile(path, []byte("context: network-fabric-test\n"), 0o600); err != nil {
			t.Fatalf("write Talos client configuration: %v", err)
		}
		if err := talosConfigReadyz(path)(nil); err != nil {
			t.Fatalf("expected readable Talos client configuration to pass readiness: %v", err)
		}
	})
}
