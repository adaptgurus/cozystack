// SPDX-License-Identifier: Apache-2.0

package option

import (
	"context"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	dynamicfake "k8s.io/client-go/dynamic/fake"
)

func TestHCINetworkOptionProviderIsTenantScoped(t *testing.T) {
	gvk := gvrNADs.GroupVersion().WithKind("NetworkAttachmentDefinition")
	dyn := dynamicfake.NewSimpleDynamicClientWithCustomListKinds(runtime.NewScheme(), listKinds())
	for _, object := range []struct {
		namespace string
		name      string
	}{
		{namespace: "tenant-a", name: "vm-network-production"},
		{namespace: "tenant-a", name: "legacy-external"},
		{namespace: "tenant-b", name: "vm-network-restricted"},
	} {
		obj := newObj(gvk, object.namespace, object.name, nil)
		if _, err := dyn.Resource(gvrNADs).Namespace(object.namespace).Create(context.Background(), obj, metav1.CreateOptions{}); err != nil {
			t.Fatalf("seed NAD %s/%s: %v", object.namespace, object.name, err)
		}
	}

	provider := DefaultProviders(dyn)["network"]
	items, err := provider(context.Background(), "tenant-a")
	if err != nil {
		t.Fatalf("network provider: %v", err)
	}

	got := values(items)
	want := []string{"legacy-external", "vm-network-production"}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("tenant-a network options: got %v want %v", got, want)
	}
	for _, value := range got {
		if value == "vm-network-restricted" {
			t.Fatalf("cross-tenant NAD leaked into tenant-a options: %v", got)
		}
	}

	empty, err := provider(context.Background(), "")
	if err != nil {
		t.Fatalf("network provider without namespace: %v", err)
	}
	if len(empty) != 0 {
		t.Fatalf("network provider without tenant namespace must return no options, got %v", values(empty))
	}
}

func TestHCINetworkOptionProviderReturnsExactNADIdentity(t *testing.T) {
	gvk := gvrNADs.GroupVersion().WithKind("NetworkAttachmentDefinition")
	dyn := dynamicfake.NewSimpleDynamicClientWithCustomListKinds(runtime.NewScheme(), listKinds())
	obj := newObj(gvk, "tenant-a", "vm-network-production", nil)
	if _, err := dyn.Resource(gvrNADs).Namespace("tenant-a").Create(context.Background(), obj, metav1.CreateOptions{}); err != nil {
		t.Fatalf("seed NAD tenant-a/vm-network-production: %v", err)
	}

	items, err := DefaultProviders(dyn)["network"](context.Background(), "tenant-a")
	if err != nil {
		t.Fatalf("network provider: %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("network provider returned %d items, want 1", len(items))
	}
	if items[0].Value != "vm-network-production" {
		t.Fatalf("network option value = %q, want exact tenant-local NAD name", items[0].Value)
	}
}

func TestHCINetworkOptionProviderGVRMatchesMultusAPI(t *testing.T) {
	if gvrNADs.Group != "k8s.cni.cncf.io" || gvrNADs.Version != "v1" || gvrNADs.Resource != "network-attachment-definitions" {
		t.Fatalf("network provider GVR = %v, want k8s.cni.cncf.io/v1 network-attachment-definitions", gvrNADs)
	}
}
