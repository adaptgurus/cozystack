// SPDX-License-Identifier: Apache-2.0

package vmnetworkadmission

import (
	"context"
	"testing"

	"github.com/cozystack/cozystack/pkg/tenantresolver"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	dynamicfake "k8s.io/client-go/dynamic/fake"
)

func authorizedFabricAndTenant(grants []interface{}, tenantStatusNamespace string) (*unstructured.Unstructured, *unstructured.Unstructured) {
	fabric := &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "infrastructure.cozystack.io/v1alpha1",
		"kind":       "NetworkFabric",
		"metadata": map[string]interface{}{
			"name": "fabric-prod",
		},
		"spec": map[string]interface{}{
			"networks": []interface{}{map[string]interface{}{
				"name":           "prod",
				"bridge":         "br-vlan120",
				"vlan":           int64(120),
				"allowedTenants": grants,
			}},
		},
	}}
	fabric.SetGroupVersionKind(networkFabricGVR.GroupVersion().WithKind("NetworkFabric"))

	tenant := &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "apps.cozystack.io/v1alpha1",
		"kind":       "Tenant",
		"metadata": map[string]interface{}{
			"namespace": "tenant-system",
			"name":      "tenant-a",
		},
		"status": map[string]interface{}{
			"namespace": tenantStatusNamespace,
		},
	}}
	tenant.SetGroupVersionKind(tenantresolver.TenantGVR.GroupVersion().WithKind("Tenant"))
	return fabric, tenant
}

func TestTenantNamespaceAllowedUsesAuthoritativeTenantStatusNamespace(t *testing.T) {
	grants := []interface{}{map[string]interface{}{"controlNamespace": "tenant-system", "name": "tenant-a"}}
	fabric, tenant := authorizedFabricAndTenant(grants, "workload-a")
	dyn := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), fabric, tenant)
	resolver := tenantresolver.New(dyn, nil)

	allowed, err := tenantNamespaceAllowed(context.Background(), dyn, resolver, "workload-a", "fabric-prod", "prod")
	if err != nil || !allowed {
		t.Fatalf("authoritative tenant namespace should be allowed, allowed=%v err=%v", allowed, err)
	}

	allowed, err = tenantNamespaceAllowed(context.Background(), dyn, resolver, "tenant-a", "fabric-prod", "prod")
	if err != nil {
		t.Fatalf("namespace mismatch should be a clean denial, got err=%v", err)
	}
	if allowed {
		t.Fatal("tenant object name or namespace convention must not authorize workload access")
	}
}

func TestTenantNamespaceAllowedDeniesEmptyGrantList(t *testing.T) {
	fabric, tenant := authorizedFabricAndTenant([]interface{}{}, "workload-a")
	dyn := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), fabric, tenant)
	allowed, err := tenantNamespaceAllowed(context.Background(), dyn, tenantresolver.New(dyn, nil), "workload-a", "fabric-prod", "prod")
	if err != nil {
		t.Fatalf("empty grant list should deny without lookup error: %v", err)
	}
	if allowed {
		t.Fatal("empty allowedTenants must deny by default")
	}
}

func TestTenantNamespaceAllowedFailsClosedWhenTenantStatusNamespaceMissing(t *testing.T) {
	grants := []interface{}{map[string]interface{}{"controlNamespace": "tenant-system", "name": "tenant-a"}}
	fabric, tenant := authorizedFabricAndTenant(grants, "")
	dyn := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), fabric, tenant)
	allowed, err := tenantNamespaceAllowed(context.Background(), dyn, tenantresolver.New(dyn, nil), "workload-a", "fabric-prod", "prod")
	if err == nil || allowed {
		t.Fatalf("missing Tenant.status.namespace must fail closed, allowed=%v err=%v", allowed, err)
	}
}

func TestTenantNamespaceAllowedFailsClosedOnMalformedGrant(t *testing.T) {
	fabric, tenant := authorizedFabricAndTenant([]interface{}{map[string]interface{}{"name": "tenant-a"}}, "workload-a")
	dyn := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), fabric, tenant)
	allowed, err := tenantNamespaceAllowed(context.Background(), dyn, tenantresolver.New(dyn, nil), "workload-a", "fabric-prod", "prod")
	if err == nil || allowed {
		t.Fatalf("malformed tenant grant must fail closed, allowed=%v err=%v", allowed, err)
	}
}
