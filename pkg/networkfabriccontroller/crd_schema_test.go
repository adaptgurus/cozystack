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

func TestNetworkFabricStatusFieldsSurviveStructuralPruning(t *testing.T) {
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
		t.Fatalf("NetworkFabric CRD must expose exactly one version with an OpenAPI schema")
	}

	var internal apiextensions.JSONSchemaProps
	if err := apiextensionsv1.Convert_v1_JSONSchemaProps_To_apiextensions_JSONSchemaProps(
		crd.Spec.Versions[0].Schema.OpenAPIV3Schema,
		&internal,
		nil,
	); err != nil {
		t.Fatalf("convert NetworkFabric schema: %v", err)
	}
	structural, err := structuralschema.NewStructural(&internal)
	if err != nil {
		t.Fatalf("build structural NetworkFabric schema: %v", err)
	}

	obj := map[string]interface{}{
		"apiVersion": "infrastructure.cozystack.io/v1alpha1",
		"kind":       "NetworkFabric",
		"metadata": map[string]interface{}{
			"name": "fabric-prod",
		},
		"spec": map[string]interface{}{
			"provider":                      "talos",
			"protectedManagementInterfaces": []interface{}{"eth0"},
			"networks":                      []interface{}{},
		},
		"status": map[string]interface{}{
			"observedGeneration": int64(7),
			"phase":              "Reconciling",
			"activeNode":         "node-01",
			"conditions": []interface{}{
				map[string]interface{}{
					"type":               "Ready",
					"status":             "False",
					"observedGeneration": int64(7),
					"lastTransitionTime": "2026-08-27T12:00:00Z",
					"reason":             "RollingUpdate",
					"message":            "reconciling node node-01",
				},
			},
			"nodes": []interface{}{
				map[string]interface{}{
					"name":                "node-01",
					"phase":               "Ready",
					"observedGeneration":  int64(7),
					"lastAppliedRevision": "rev-123",
					"managementReachable": true,
					"message":             "Talos network configuration verified",
					"lastVerifiedAt":      "2026-08-27T12:00:01Z",
					"rollbackState":       "NotRequired",
					"appliedNetworks": []interface{}{
						map[string]interface{}{
							"name":          "production",
							"uplink":        "bond0",
							"vlan":          int64(120),
							"vlanInterface": "vlan120",
							"bridge":        "br-vm-120",
							"mtu":           int64(1500),
							"migration":     false,
						},
					},
				},
			},
			"migration": map[string]interface{}{
				"configured": true,
				"network":    "migration",
				"bridge":     "br-migration",
				"readyNodes": []interface{}{"node-01"},
				"unavailableNodes": []interface{}{
					map[string]interface{}{
						"name":   "node-02",
						"reason": "bridge br-migration is unavailable",
					},
				},
			},
			"unknownStatusField": "must-be-pruned",
		},
	}

	pruning.Prune(obj, structural, true)

	status, ok := obj["status"].(map[string]interface{})
	if !ok {
		t.Fatalf("status was pruned entirely: %#v", obj)
	}
	for _, field := range []string{"observedGeneration", "phase", "activeNode", "conditions", "nodes", "migration"} {
		if _, ok := status[field]; !ok {
			t.Errorf("status.%s was pruned by the CRD schema", field)
		}
	}
	if _, ok := status["unknownStatusField"]; ok {
		t.Errorf("unknown status field unexpectedly survived pruning")
	}

	nodes, ok := status["nodes"].([]interface{})
	if !ok || len(nodes) != 1 {
		t.Fatalf("status.nodes was pruned or malformed: %#v", status["nodes"])
	}
	node, ok := nodes[0].(map[string]interface{})
	if !ok {
		t.Fatalf("status.nodes[0] malformed: %#v", nodes[0])
	}
	for _, field := range []string{"name", "phase", "observedGeneration", "lastAppliedRevision", "managementReachable", "message", "appliedNetworks", "lastVerifiedAt", "rollbackState"} {
		if _, ok := node[field]; !ok {
			t.Errorf("status.nodes[0].%s was pruned by the CRD schema", field)
		}
	}
	appliedNetworks, ok := node["appliedNetworks"].([]interface{})
	if !ok || len(appliedNetworks) != 1 {
		t.Fatalf("status.nodes[0].appliedNetworks was pruned or malformed: %#v", node["appliedNetworks"])
	}
	appliedNetwork, ok := appliedNetworks[0].(map[string]interface{})
	if !ok {
		t.Fatalf("status.nodes[0].appliedNetworks[0] malformed: %#v", appliedNetworks[0])
	}
	for _, field := range []string{"name", "uplink", "vlan", "vlanInterface", "bridge", "mtu", "migration"} {
		if _, ok := appliedNetwork[field]; !ok {
			t.Errorf("status.nodes[0].appliedNetworks[0].%s was pruned by the CRD schema", field)
		}
	}

	migration, ok := status["migration"].(map[string]interface{})
	if !ok {
		t.Fatalf("status.migration was pruned or malformed: %#v", status["migration"])
	}
	for _, field := range []string{"configured", "network", "bridge", "readyNodes", "unavailableNodes"} {
		if _, ok := migration[field]; !ok {
			t.Errorf("status.migration.%s was pruned by the CRD schema", field)
		}
	}
	unavailable, ok := migration["unavailableNodes"].([]interface{})
	if !ok || len(unavailable) != 1 {
		t.Fatalf("status.migration.unavailableNodes was pruned or malformed: %#v", migration["unavailableNodes"])
	}
	unavailableNode, ok := unavailable[0].(map[string]interface{})
	if !ok {
		t.Fatalf("status.migration.unavailableNodes[0] malformed: %#v", unavailable[0])
	}
	for _, field := range []string{"name", "reason"} {
		if _, ok := unavailableNode[field]; !ok {
			t.Errorf("status.migration.unavailableNodes[0].%s was pruned by the CRD schema", field)
		}
	}
}
