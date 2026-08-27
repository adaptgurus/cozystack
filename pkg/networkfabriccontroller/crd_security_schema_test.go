// SPDX-License-Identifier: Apache-2.0

package networkfabriccontroller

import (
	"os"
	"path/filepath"
	"testing"

	apiextensions "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions"
	apiextensionsv1 "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/v1"
	structuralschema "k8s.io/apiextensions-apiserver/pkg/apiserver/schema"
	"k8s.io/apiextensions-apiserver/pkg/apiserver/schema/pruning"
	"sigs.k8s.io/yaml"
)

func networkFabricStructuralSchemaForTest(t *testing.T) *structuralschema.Structural {
	t.Helper()
	path := filepath.Join("..", "..", "packages", "system", "network-fabric-crd", "templates", "crd.yaml")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read NetworkFabric CRD: %v", err)
	}
	var crd apiextensionsv1.CustomResourceDefinition
	if err := yaml.Unmarshal(data, &crd); err != nil {
		t.Fatalf("parse NetworkFabric CRD: %v", err)
	}
	if len(crd.Spec.Versions) != 1 || crd.Spec.Versions[0].Schema == nil || crd.Spec.Versions[0].Schema.OpenAPIV3Schema == nil {
		t.Fatal("NetworkFabric CRD must expose one structural OpenAPI schema")
	}
	var internal apiextensions.JSONSchemaProps
	if err := apiextensionsv1.Convert_v1_JSONSchemaProps_To_apiextensions_JSONSchemaProps(crd.Spec.Versions[0].Schema.OpenAPIV3Schema, &internal, nil); err != nil {
		t.Fatalf("convert NetworkFabric schema: %v", err)
	}
	structural, err := structuralschema.NewStructural(&internal)
	if err != nil {
		t.Fatalf("build structural NetworkFabric schema: %v", err)
	}
	return structural
}

func TestNetworkFabricSecurityAndTransactionFieldsSurviveStructuralPruning(t *testing.T) {
	structural := networkFabricStructuralSchemaForTest(t)
	obj := map[string]interface{}{
		"apiVersion": "infrastructure.cozystack.io/v1alpha1",
		"kind":       "NetworkFabric",
		"metadata":   map[string]interface{}{"name": "fabric-prod"},
		"spec": map[string]interface{}{
			"provider":     "talos",
			"nodeSelector": map[string]interface{}{"hci.cozystack.io/networking": "enabled"},
			"protectedManagementInterfaces": []interface{}{"eth0"},
			"networks": []interface{}{map[string]interface{}{
				"name":          "prod",
				"uplink":        "eth1",
				"vlan":          int64(120),
				"vlanInterface": "eth1.120",
				"bridge":        "br-vlan120",
				"mtu":           int64(1500),
				"allowedTenants": []interface{}{map[string]interface{}{
					"controlNamespace": "tenant-system",
					"name":             "tenant-a",
				}},
				"unknownNetworkField": "prune-me",
			}},
		},
		"status": map[string]interface{}{
			"observedGeneration": int64(9),
			"phase":              "Reconciling",
			"nodes": []interface{}{map[string]interface{}{
				"name":                "node-01",
				"phase":               "Reconciling",
				"transactionPhase":    "TryApplied",
				"transactionRevision": "rev-fingerprint",
				"transactionDeadline": "2026-08-27T18:00:00Z",
				"transactionNetworks": []interface{}{map[string]interface{}{
					"name":          "prod",
					"uplink":        "eth1",
					"vlan":          int64(120),
					"vlanInterface": "eth1.120",
					"bridge":        "br-vlan120",
					"mtu":           int64(1500),
					"migration":     false,
				}},
				"unknownTransactionField": "prune-me",
			}},
		},
	}

	pruning.Prune(obj, structural, true)

	spec := obj["spec"].(map[string]interface{})
	networks := spec["networks"].([]interface{})
	network := networks[0].(map[string]interface{})
	grants, ok := network["allowedTenants"].([]interface{})
	if !ok || len(grants) != 1 {
		t.Fatalf("spec.networks[0].allowedTenants was pruned: %#v", network)
	}
	grant := grants[0].(map[string]interface{})
	for _, field := range []string{"controlNamespace", "name"} {
		if _, ok := grant[field]; !ok {
			t.Errorf("allowedTenants[0].%s was pruned", field)
		}
	}
	if _, ok := network["unknownNetworkField"]; ok {
		t.Error("unknown spec network field unexpectedly survived pruning")
	}

	status := obj["status"].(map[string]interface{})
	nodes := status["nodes"].([]interface{})
	node := nodes[0].(map[string]interface{})
	for _, field := range []string{"transactionPhase", "transactionRevision", "transactionDeadline", "transactionNetworks"} {
		if _, ok := node[field]; !ok {
			t.Errorf("status.nodes[0].%s was pruned", field)
		}
	}
	if _, ok := node["unknownTransactionField"]; ok {
		t.Error("unknown transaction status field unexpectedly survived pruning")
	}
	txNetworks, ok := node["transactionNetworks"].([]interface{})
	if !ok || len(txNetworks) != 1 {
		t.Fatalf("transactionNetworks was pruned or malformed: %#v", node["transactionNetworks"])
	}
}
