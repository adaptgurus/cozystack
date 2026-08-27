// SPDX-License-Identifier: Apache-2.0

package option

import (
	"context"
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	dynamicfake "k8s.io/client-go/dynamic/fake"
)

func mediaTestObject(gvk schema.GroupVersionKind, namespace, name string, spec map[string]interface{}, annotations map[string]string) *unstructured.Unstructured {
	o := newObj(gvk, namespace, name, spec)
	o.SetAnnotations(annotations)
	return o
}

func TestISOProviderSeparatesPlatformISOsFromGoldenImages(t *testing.T) {
	kinds := listKinds()
	kinds[gvrDataVolumes] = "DataVolumeList"
	gvk := gvrDataVolumes.GroupVersion().WithKind("DataVolume")
	dyn := dynamicfake.NewSimpleDynamicClientWithCustomListKinds(runtime.NewScheme(), kinds,
		mediaTestObject(gvk, publicImagesNamespace, "vm-default-isos-windows-server-2025", nil, map[string]string{
			"vm-disk.cozystack.io/optical":               "true",
			"vm-default-isos.cozystack.io/name":          "Windows Server 2025",
			"vm-default-isos.cozystack.io/category":      "installer",
			"vm-default-isos.cozystack.io/os-name":       "Windows Server",
			"vm-default-isos.cozystack.io/os-version":    "2025",
			"vm-default-isos.cozystack.io/description":   "Windows installation media",
		}),
		mediaTestObject(gvk, publicImagesNamespace, "vm-default-isos-virtio-win", nil, map[string]string{
			"vm-disk.cozystack.io/optical":          "true",
			"vm-default-isos.cozystack.io/name":     "VirtIO Drivers",
			"vm-default-isos.cozystack.io/category": "drivers",
		}),
		mediaTestObject(gvk, publicImagesNamespace, "vm-default-images-ubuntu-24.04", nil, map[string]string{
			"vm-disk.cozystack.io/optical": "false",
		}),
		mediaTestObject(gvk, "other", "vm-default-isos-hidden", nil, map[string]string{
			"vm-disk.cozystack.io/optical": "true",
		}),
	)

	items, err := isoProvider(dyn)(context.Background(), "tenant-a")
	if err != nil {
		t.Fatalf("iso provider: %v", err)
	}
	if got := values(items); len(got) != 2 || got[0] != "virtio-win" || got[1] != "windows-server-2025" {
		t.Fatalf("iso values = %v", got)
	}
	if items[1].Label != "Windows Server 2025" {
		t.Fatalf("Windows ISO label = %q", items[1].Label)
	}
	if items[1].Description == "" {
		t.Fatal("Windows ISO description should include catalog metadata")
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
}
