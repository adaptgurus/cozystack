// SPDX-License-Identifier: Apache-2.0

package main

import (
	"os"
	"path/filepath"
	"testing"
)

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
