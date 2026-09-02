# This fragment is concatenated after diagnose-cluster-machine-plan-details.sh.
# It reuses the authenticated kubectl function and protected temporary directory.

for machine_name in custom-ebb7c4ae04fd custom-81a2c5e94b13 custom-a5a2c67354be; do
  if ! k -n local get secret "$machine_name" --show-managed-fields -o json > "$work/owner-${machine_name}.json" 2>"$work/owner-${machine_name}.stderr"; then
    printf '{"missing":true,"resource":"secrets","namespace":"local","name":"%s"}\n' \
      "$machine_name" > "$work/owner-${machine_name}.json"
  fi
  if ! k -n fleet-local get machines.cluster.x-k8s.io "$machine_name" --show-managed-fields -o json > "$work/managed-capi-${machine_name}.json" 2>"$work/managed-capi-${machine_name}.stderr"; then
    printf '{"missing":true,"resource":"machines.cluster.x-k8s.io","namespace":"fleet-local","name":"%s"}\n' \
      "$machine_name" > "$work/managed-capi-${machine_name}.json"
  fi
  if ! k -n fleet-local get rkebootstraps.rke.cattle.io "$machine_name" --show-managed-fields -o json > "$work/managed-bootstrap-${machine_name}.json" 2>"$work/managed-bootstrap-${machine_name}.stderr"; then
    printf '{"missing":true,"resource":"rkebootstraps.rke.cattle.io","namespace":"fleet-local","name":"%s"}\n' \
      "$machine_name" > "$work/managed-bootstrap-${machine_name}.json"
  fi
  if ! k -n fleet-local get custommachines.rke.cattle.io "$machine_name" --show-managed-fields -o json > "$work/managed-custom-${machine_name}.json" 2>"$work/managed-custom-${machine_name}.stderr"; then
    printf '{"missing":true,"resource":"custommachines.rke.cattle.io","namespace":"fleet-local","name":"%s"}\n' \
      "$machine_name" > "$work/managed-custom-${machine_name}.json"
  fi
done

python3 - "$work" <<'PY'
import base64
import hashlib
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
MACHINES = {
    "sen1": "custom-ebb7c4ae04fd",
    "sen2": "custom-81a2c5e94b13",
    "sen3": "custom-a5a2c67354be",
}
ROLE_LABELS = {
    "cluster.x-k8s.io/control-plane",
    "rke.cattle.io/control-plane-role",
    "rke.cattle.io/etcd-role",
    "rke.cattle.io/worker-role",
}
SENSITIVE = re.compile(r"token|password|credential|private.?key|client.?key|kubeconfig|certificate.?key", re.I)
DROP_ANNOTATION = re.compile(r"objectset\.rio\.cattle\.io/applied|kubectl\.kubernetes\.io/last-applied-configuration", re.I)


def load(path):
    try:
        return json.loads((root / path).read_text(encoding="utf-8"))
    except Exception as exc:
        return {"missing": True, "loadError": f"{type(exc).__name__}: {exc}", "source": path}


def safe_map(value, annotation=False):
    out = {}
    for key, child in (value or {}).items():
        text = str(key)
        if annotation and DROP_ANNOTATION.search(text):
            continue
        if SENSITIVE.search(text):
            out[text] = "[REDACTED]"
        elif isinstance(child, str) and len(child) > 2048:
            out[text] = f"[OMITTED-LONG-STRING:{len(child)}]"
        else:
            out[text] = child
    return out


def decode_field_key(key):
    if key.startswith("f:"):
        return key[2:].replace("~1", "/").replace("~0", "~")
    if key.startswith("k:"):
        return key
    if key == ".":
        return ""
    return key


def flatten(value, prefix=""):
    result = []
    if not isinstance(value, dict):
        return result
    for raw_key, child in value.items():
        key = decode_field_key(str(raw_key))
        if not key:
            path = prefix
        elif key.startswith("k:"):
            path = f"{prefix}[{key[2:]}]"
        else:
            path = f"{prefix}.{key}" if prefix else key
        if path:
            result.append(path)
        result.extend(flatten(child, path))
    return result


def managed_summary(obj):
    summaries = []
    for entry in (obj.get("metadata") or {}).get("managedFields") or []:
        paths = flatten(entry.get("fieldsV1") or {})
        role_paths = sorted(
            {
                path
                for path in paths
                if any(label in path for label in ROLE_LABELS)
                or path.startswith("spec.bootstrap")
                or path.startswith("spec.infrastructureRef")
                or path.startswith("spec.providerID")
            }
        )
        summaries.append(
            {
                "manager": entry.get("manager"),
                "operation": entry.get("operation"),
                "apiVersion": entry.get("apiVersion"),
                "time": entry.get("time"),
                "subresource": entry.get("subresource"),
                "roleRelevantPaths": role_paths,
            }
        )
    return summaries


def resource_summary(obj, source):
    if obj.get("missing"):
        return {"source": source, **obj}
    metadata = obj.get("metadata") or {}
    labels = safe_map(metadata.get("labels"))
    return {
        "source": source,
        "apiVersion": obj.get("apiVersion"),
        "kind": obj.get("kind"),
        "namespace": metadata.get("namespace"),
        "name": metadata.get("name"),
        "uid": metadata.get("uid"),
        "resourceVersion": metadata.get("resourceVersion"),
        "generation": metadata.get("generation"),
        "creationTimestamp": metadata.get("creationTimestamp"),
        "ownerReferences": metadata.get("ownerReferences") or [],
        "roleLabels": {key: value for key, value in labels.items() if key in ROLE_LABELS},
        "selectedLabels": {
            key: value
            for key, value in labels.items()
            if key in ROLE_LABELS
            or key in {
                "rke.cattle.io/node-name",
                "rke.cattle.io/machine-id",
                "rke.cattle.io/cluster-name",
                "cluster.x-k8s.io/cluster-name",
                "harvesterhci.io/managed",
            }
        },
        "annotations": safe_map(metadata.get("annotations"), annotation=True),
        "managedFields": managed_summary(obj),
    }


def owner_secret_summary(secret, node):
    source = f"MachineRequest owner Secret {node}"
    if secret.get("missing"):
        return {"source": source, **secret}
    metadata = secret.get("metadata") or {}
    data = secret.get("data") or {}
    request = None
    decode_error = None
    if "data" in data:
        try:
            request = json.loads(base64.b64decode(data["data"]).decode("utf-8"))
        except Exception as exc:
            decode_error = f"{type(exc).__name__}: {exc}"
    selected_request = {}
    if isinstance(request, dict):
        for key in (
            "role-control-plane",
            "role-etcd",
            "role-worker",
            "node-name",
            "address",
            "internal-address",
            "labels",
        ):
            if key in request:
                selected_request[key] = request[key]
    return {
        "source": source,
        "namespace": metadata.get("namespace"),
        "name": metadata.get("name"),
        "uid": metadata.get("uid"),
        "resourceVersion": metadata.get("resourceVersion"),
        "creationTimestamp": metadata.get("creationTimestamp"),
        "type": secret.get("type"),
        "roleLabels": {
            key: value
            for key, value in safe_map(metadata.get("labels")).items()
            if key in ROLE_LABELS
        },
        "annotations": safe_map(metadata.get("annotations"), annotation=True),
        "dataKeys": sorted(data.keys()),
        "dataKeyEvidence": {
            key: {
                "encodedBytes": len(str(value)),
                "encodedSha256": hashlib.sha256(str(value).encode("utf-8")).hexdigest(),
            }
            for key, value in data.items()
        },
        "selectedMachineRequestFields": selected_request,
        "decodeError": decode_error,
        "managedFields": managed_summary(secret),
    }


print("===OWNER-SECRET-AND-MANAGED-FIELD-TRACE===")
trace = {}
for node, name in MACHINES.items():
    owner = load(f"owner-{name}.json")
    capi = load(f"managed-capi-{name}.json")
    bootstrap = load(f"managed-bootstrap-{name}.json")
    custom = load(f"managed-custom-{name}.json")
    trace[node] = {
        "ownerSecret": owner_secret_summary(owner, node),
        "capiMachine": resource_summary(capi, f"CAPI Machine {node}"),
        "rkeBootstrap": resource_summary(bootstrap, f"RKEBootstrap {node}"),
        "customMachine": resource_summary(custom, f"CustomMachine {node}"),
    }
print(json.dumps(trace, sort_keys=True, default=str))

sen2 = trace["sen2"]
role_managers = []
for resource_name in ("capiMachine", "rkeBootstrap", "customMachine"):
    for manager in sen2[resource_name].get("managedFields") or []:
        if manager.get("roleRelevantPaths"):
            role_managers.append({"resource": resource_name, **manager})
assessment = {
    "sen2OwnerSecretPresent": not bool(sen2["ownerSecret"].get("missing")),
    "sen2OwnerSecretSelectedRequestFields": sen2["ownerSecret"].get("selectedMachineRequestFields") or {},
    "sen2CurrentRoleLabels": {
        "capiMachine": sen2["capiMachine"].get("roleLabels") or {},
        "rkeBootstrap": sen2["rkeBootstrap"].get("roleLabels") or {},
        "customMachine": sen2["customMachine"].get("roleLabels") or {},
    },
    "sen2RoleRelevantFieldManagers": role_managers,
    "workerOnlyComparison": {
        "sen3CapiMachine": trace["sen3"]["capiMachine"].get("roleLabels") or {},
        "sen3RkeBootstrap": trace["sen3"]["rkeBootstrap"].get("roleLabels") or {},
        "sen3CustomMachine": trace["sen3"]["customMachine"].get("roleLabels") or {},
    },
    "clusterStateModified": False,
    "credentialValuesWrittenToEvidence": False,
    "productionReleaseApproved": False,
}
print("===OWNER-ROLE-SOURCE-ASSESSMENT===")
print(json.dumps(assessment, sort_keys=True, default=str))
print("===OWNER-DIAGNOSTIC-COMPLETE===")
PY
