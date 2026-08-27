// SPDX-License-Identifier: Apache-2.0

package option

import (
	"context"
	"testing"

	"k8s.io/apimachinery/pkg/runtime"
	dynamicfake "k8s.io/client-go/dynamic/fake"
)

func TestISOProviderSeparatesPlatformISOsFromGoldenImages(t *testing.T) {
	gvk := gvrPVCs.GroupVersion().WithKind("PersistentVolumeClaim")
	dyn := dynamicfake.NewSimpleDynamicClientWithCustomListKinds(runtime.NewScheme(), listKinds(),
		newObj(gvk, publicImagesNamespace, "vm-default-isos-windows-server-2025", nil),
		newObj(gvk, publicImagesNamespace, "vm-default-isos-virtio-win", nil),
		newObj(gvk, publicImagesNamespace, "vm-default-images-ubuntu-24.04", nil),
		newObj(gvk, "other", "vm-default-isos-hidden", nil),
	)

	items, err := isoProvider(dyn)(context.Background(), "tenant-a")
	if err != nil {
		t.Fatalf("iso provider: %v", err)
	}
	if got := values(items); len(got) != 2 || got[0] != "virtio-win" || got[1] != "windows-server-2025" {
		t.Fatalf("iso values = %v", got)
	}
	if items[0].Label != "virtio-win" || items[1].Label != "windows-server-2025" {
		t.Fatalf("ISO labels must match stable catalog values, got %#v", items)
	}
}

func TestISOProviderIsPlatformScoped(t *testing.T) {
	gvk := gvrPVCs.GroupVersion().WithKind("PersistentVolumeClaim")
	dyn := dynamicfake.NewSimpleDynamicClientWithCustomListKinds(runtime.NewScheme(), listKinds(),
		newObj(gvk, publicImagesNamespace, "vm-default-isos-rescue", nil),
		newObj(gvk, "tenant-a", "vm-default-isos-private", nil),
	)

	for _, namespace := range []string{"", "tenant-a", "tenant-b"} {
		items, err := isoProvider(dyn)(context.Background(), namespace)
		if err != nil {
			t.Fatalf("iso provider namespace %q: %v", namespace, err)
		}
		if got := values(items); len(got) != 1 || got[0] != "rescue" {
			t.Fatalf("iso values for namespace %q = %v, want platform catalog only", namespace, got)
		}
	}
}

func TestOpticalDiskProviderIsTenantScopedAndFiltersBlockDisks(t *testing.T) {
	gvk := gvrVMDisks.GroupVersion().WithKind("VMDisk")
	dyn := dynamicfake.NewSimpleDynamicClientWithCustomListKinds(runtime.NewScheme(), listKinds(),
		newObj(gvk, "tenant-a", "windows-install", map[string]interface{}{
			"optical":       true,
			"displayName":   "Windows Installer",
			"mediaCategory": "installer",
		}),
		newObj(gvk, "tenant-a", "virtio", map[string]interface{}{
			"optical": false,
			"source": map[string]interface{}{"iso": map[string]interface{}{"name": "virtio-win"}},
		}),
		newObj(gvk, "tenant-a", "system-disk", map[string]interface{}{
			"optical": false,
		}),
		newObj(gvk, "tenant-b", "other-tenant-iso", map[string]interface{}{
			"optical": true,
		}),
	)

	items, err := opticalDiskProvider(dyn)(context.Background(), "tenant-a")
	if err != nil {
		t.Fatalf("opticaldisk provider: %v", err)
	}
	got := values(items)
	if len(got) != 2 || got[0] != "virtio" || got[1] != "windows-install" {
		t.Fatalf("opticaldisk values = %v", got)
	}
	if items[1].Label != "Windows Installer" {
		t.Fatalf("display label = %q", items[1].Label)
	}

	empty, err := opticalDiskProvider(dyn)(context.Background(), "")
	if err != nil {
		t.Fatalf("opticaldisk provider empty namespace: %v", err)
	}
	if len(empty) != 0 {
		t.Fatalf("opticaldisk provider without tenant namespace returned %v", values(empty))
	}
}
