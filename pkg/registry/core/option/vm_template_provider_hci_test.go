// SPDX-License-Identifier: Apache-2.0

package option

import (
	"context"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	dynamicfake "k8s.io/client-go/dynamic/fake"
)

func TestHCIVMTemplateProvidersAreTenantScopedAndReadyOnly(t *testing.T) {
	kinds := listKinds()
	kinds[gvrVMInstances] = "VMInstanceList"
	kinds[gvrVMTemplateOperations] = "VMTemplateOperationList"
	dyn := dynamicfake.NewSimpleDynamicClientWithCustomListKinds(runtime.NewScheme(), kinds)

	vmGVK := gvrVMInstances.GroupVersion().WithKind("VMInstance")
	for _, seed := range []struct{ ns, name string }{{"tenant-a", "app-01"}, {"tenant-b", "other"}} {
		if _, err := dyn.Resource(gvrVMInstances).Namespace(seed.ns).Create(context.Background(), newObj(vmGVK, seed.ns, seed.name, nil), metav1.CreateOptions{}); err != nil {
			t.Fatalf("seed VMInstance %s/%s: %v", seed.ns, seed.name, err)
		}
	}

	opGVK := gvrVMTemplateOperations.GroupVersion().WithKind("VMTemplateOperation")
	for _, seed := range []struct{ ns, name, phase string }{{"tenant-a", "golden", "Ready"}, {"tenant-a", "capturing", "Capturing"}, {"tenant-b", "foreign", "Ready"}} {
		op := newObj(opGVK, seed.ns, seed.name, nil)
		op.Object["status"] = map[string]interface{}{"phase": seed.phase}
		if _, err := dyn.Resource(gvrVMTemplateOperations).Namespace(seed.ns).Create(context.Background(), op, metav1.CreateOptions{}); err != nil {
			t.Fatalf("seed VMTemplateOperation %s/%s: %v", seed.ns, seed.name, err)
		}
	}

	vmItems, err := DefaultProviders(dyn)["vminstance"](context.Background(), "tenant-a")
	if err != nil {
		t.Fatalf("vminstance provider: %v", err)
	}
	if got := values(vmItems); len(got) != 1 || got[0] != "app-01" {
		t.Fatalf("vminstance options = %v, want [app-01]", got)
	}

	tplItems, err := DefaultProviders(dyn)["vmtemplate"](context.Background(), "tenant-a")
	if err != nil {
		t.Fatalf("vmtemplate provider: %v", err)
	}
	if got := values(tplItems); len(got) != 1 || got[0] != "golden" {
		t.Fatalf("vmtemplate options = %v, want only Ready tenant template [golden]", got)
	}

	if items, err := DefaultProviders(dyn)["vmtemplate"](context.Background(), ""); err != nil || len(items) != 0 {
		t.Fatalf("vmtemplate provider without namespace = %v, %v; want empty", values(items), err)
	}
}
