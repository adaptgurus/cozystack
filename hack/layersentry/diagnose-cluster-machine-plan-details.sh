#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

: "${LAYERSENTRY_NODE_PASSWORD_B64:?LAYERSENTRY_NODE_PASSWORD_B64 is required}"

work=$(mktemp -d /tmp/layersentry-machine-plan-details.XXXXXX)
cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

printf '%s' "$LAYERSENTRY_NODE_PASSWORD_B64" | base64 -d > "$work/node-password"
printf '\n' >> "$work/node-password"
chmod 0600 "$work/node-password"
unset LAYERSENTRY_NODE_PASSWORD_B64

if ! sudo -n true >/dev/null 2>&1; then
  sudo -S -p '' -v < "$work/node-password"
fi

kubectl_path=''
for candidate in \
  /var/lib/rancher/rke2/bin/kubectl \
  /opt/rke2/bin/kubectl \
  /usr/local/bin/kubectl \
  /usr/bin/kubectl; do
  if [ -x "$candidate" ]; then
    kubectl_path="$candidate"
    break
  fi
done
if [ -z "$kubectl_path" ]; then
  echo 'LAYERSENTRY_MACHINE_PLAN_DETAIL_ERROR:kubectl-not-found'
  exit 81
fi

kubeconfig=/etc/rancher/rke2/rke2.yaml
k() {
  sudo -n "$kubectl_path" --kubeconfig "$kubeconfig" "$@"
}

capture_namespaced() {
  local resource=$1
  local name=$2
  local destination=$3
  if ! k -n fleet-local get "$resource" "$name" -o json > "$destination" 2>"${destination}.stderr"; then
    printf '{"missing":true,"resource":"%s","namespace":"fleet-local","name":"%s"}\n' \
      "$resource" "$name" > "$destination"
  fi
}

capture_cluster_scoped() {
  local resource=$1
  local name=$2
  local destination=$3
  if ! k get "$resource" "$name" -o json > "$destination" 2>"${destination}.stderr"; then
    printf '{"missing":true,"resource":"%s","name":"%s"}\n' \
      "$resource" "$name" > "$destination"
  fi
}

sen2_machine=custom-81a2c5e94b13
sen3_machine=custom-a5a2c67354be
sen1_machine=custom-ebb7c4ae04fd

capture_namespaced machines.cluster.x-k8s.io "$sen1_machine" "$work/capi-sen1.json"
capture_namespaced machines.cluster.x-k8s.io "$sen2_machine" "$work/capi-sen2.json"
capture_namespaced machines.cluster.x-k8s.io "$sen3_machine" "$work/capi-sen3.json"
capture_namespaced custommachines.rke.cattle.io "$sen1_machine" "$work/custom-sen1.json"
capture_namespaced custommachines.rke.cattle.io "$sen2_machine" "$work/custom-sen2.json"
capture_namespaced custommachines.rke.cattle.io "$sen3_machine" "$work/custom-sen3.json"
capture_namespaced rkebootstraps.rke.cattle.io "$sen1_machine" "$work/bootstrap-sen1.json"
capture_namespaced rkebootstraps.rke.cattle.io "$sen2_machine" "$work/bootstrap-sen2.json"
capture_namespaced rkebootstraps.rke.cattle.io "$sen3_machine" "$work/bootstrap-sen3.json"
capture_namespaced rkecontrolplanes.rke.cattle.io local "$work/rke-control-plane.json"
capture_namespaced clusters.provisioning.cattle.io local "$work/provisioning-cluster.json"
capture_namespaced clusters.cluster.x-k8s.io local "$work/capi-cluster.json"
capture_namespaced secrets "$sen1_machine-machine-plan" "$work/plan-sen1.json"
capture_namespaced secrets "$sen2_machine-machine-plan" "$work/plan-sen2.json"
capture_namespaced secrets "$sen3_machine-machine-plan" "$work/plan-sen3.json"

if ! k -n fleet-local get events -o json > "$work/events.json" 2>"$work/events.stderr"; then
  printf '{"items":[]}\n' > "$work/events.json"
fi
if ! k get nodes -o json > "$work/nodes.json" 2>"$work/nodes.stderr"; then
  printf '{"items":[]}\n' > "$work/nodes.json"
fi
if ! k api-resources --verbs=get --namespaced=true -o name > "$work/namespaced-resources.txt" 2>/dev/null; then
  : > "$work/namespaced-resources.txt"
fi

python3 - "$work" <<'PY'
import base64
import hashlib
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])

SENSITIVE_KEY = re.compile(
    r"token|password|credential|private.?key|client.?key|kubeconfig|certificate.?key|secret.?data",
    re.I,
)
DROP_ANNOTATION = re.compile(
    r"objectset\.rio\.cattle\.io/applied|kubectl\.kubernetes\.io/last-applied-configuration",
    re.I,
)
ROLE_PATH = re.compile(
    r"control.?plane|etcd|worker|role|machineSelectorConfig|machineGlobalConfig|bootstrap|infrastructureRef|providerID|nodeName|node-name",
    re.I,
)
TARGET_NAMES = {
    "custom-ebb7c4ae04fd",
    "custom-81a2c5e94b13",
    "custom-a5a2c67354be",
    "sen1",
    "sen2",
    "sen3",
    "custom-ebb7c4ae04fd-machine-plan",
    "custom-81a2c5e94b13-machine-plan",
    "custom-a5a2c67354be-machine-plan",
}


def load(name):
    path = root / name
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        return {"missing": True, "loadError": f"{type(exc).__name__}: {exc}", "source": name}


def sanitize(value, path="$", depth=0):
    if depth > 20:
        return "[MAX-DEPTH]"
    if isinstance(value, dict):
        out = {}
        for key, child in value.items():
            text_key = str(key)
            child_path = f"{path}.{text_key}"
            if text_key in {"data", "stringData", "managedFields"}:
                continue
            if path.endswith(".annotations") and DROP_ANNOTATION.search(text_key):
                continue
            if SENSITIVE_KEY.search(text_key):
                if text_key.lower().endswith("ref") or text_key.lower().endswith("name"):
                    out[text_key] = sanitize(child, child_path, depth + 1)
                else:
                    out[text_key] = "[REDACTED]"
                continue
            out[text_key] = sanitize(child, child_path, depth + 1)
        return out
    if isinstance(value, list):
        return [sanitize(item, f"{path}[{index}]", depth + 1) for index, item in enumerate(value)]
    if isinstance(value, str):
        if re.search(r"K10[a-zA-Z0-9]{20,}::server:[a-zA-Z0-9]{20,}", value):
            return "[REDACTED-RKE2-TOKEN]"
        if len(value) > 4096:
            return f"[OMITTED-LONG-STRING:{len(value)}]"
    return value


def decode_field_key(key):
    if key.startswith("f:"):
        return key[2:].replace("~1", "/").replace("~0", "~")
    if key.startswith("k:"):
        return key
    if key == ".":
        return ""
    return key


def flatten_fields(value, prefix=""):
    paths = []
    if not isinstance(value, dict):
        return paths
    for raw_key, child in value.items():
        key = decode_field_key(str(raw_key))
        if not key:
            next_prefix = prefix
        elif key.startswith("k:"):
            next_prefix = f"{prefix}[{key[2:]}]"
        else:
            next_prefix = f"{prefix}.{key}" if prefix else key
        if next_prefix:
            paths.append(next_prefix)
        paths.extend(flatten_fields(child, next_prefix))
    return paths


def managed_field_summary(obj):
    result = []
    metadata = obj.get("metadata") if isinstance(obj, dict) else None
    for entry in (metadata or {}).get("managedFields") or []:
        if not isinstance(entry, dict):
            continue
        all_paths = flatten_fields(entry.get("fieldsV1") or {})
        selected = sorted(
            {
                path
                for path in all_paths
                if path.startswith("metadata.labels")
                or path.startswith("metadata.ownerReferences")
                or path.startswith("spec")
            }
        )
        role_selected = [path for path in selected if ROLE_PATH.search(path)]
        result.append(
            {
                "manager": entry.get("manager"),
                "operation": entry.get("operation"),
                "apiVersion": entry.get("apiVersion"),
                "time": entry.get("time"),
                "subresource": entry.get("subresource"),
                "roleRelevantPaths": role_selected[:300],
                "selectedPathCount": len(selected),
            }
        )
    return result


def object_summary(obj, source):
    if obj.get("missing"):
        return {"source": source, **obj}
    metadata = obj.get("metadata") or {}
    return {
        "source": source,
        "apiVersion": obj.get("apiVersion"),
        "kind": obj.get("kind"),
        "metadata": {
            "namespace": metadata.get("namespace"),
            "name": metadata.get("name"),
            "uid": metadata.get("uid"),
            "resourceVersion": metadata.get("resourceVersion"),
            "generation": metadata.get("generation"),
            "creationTimestamp": metadata.get("creationTimestamp"),
            "ownerReferences": sanitize(metadata.get("ownerReferences") or []),
            "finalizers": metadata.get("finalizers") or [],
            "labels": sanitize(metadata.get("labels") or {}, "$.metadata.labels"),
            "annotations": sanitize(metadata.get("annotations") or {}, "$.metadata.annotations"),
        },
        "spec": sanitize(obj.get("spec") or {}, "$.spec"),
        "status": sanitize(obj.get("status") or {}, "$.status"),
        "managedFields": managed_field_summary(obj),
    }


def iter_paths(value, prefix="$", depth=0):
    if depth > 20:
        return
    if isinstance(value, dict):
        for key, child in value.items():
            next_path = f"{prefix}.{key}"
            yield next_path, child
            yield from iter_paths(child, next_path, depth + 1)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            next_path = f"{prefix}[{index}]"
            yield next_path, child
            yield from iter_paths(child, next_path, depth + 1)


def role_values(obj):
    values = []
    for path, value in iter_paths(obj):
        if ROLE_PATH.search(path):
            safe_value = sanitize(value, path)
            if isinstance(safe_value, (dict, list)):
                encoded = json.dumps(safe_value, sort_keys=True, default=str)
                if len(encoded) > 1500:
                    safe_value = f"[STRUCTURE:{len(encoded)}]"
            values.append({"path": path, "value": safe_value})
    return values[:500]


def all_decoded_text(value, depth=0):
    if depth > 16:
        return []
    texts = []
    if isinstance(value, dict):
        for key, child in value.items():
            if str(key).lower() not in {"token", "password", "credential"}:
                texts.extend(all_decoded_text(child, depth + 1))
    elif isinstance(value, list):
        for child in value:
            texts.extend(all_decoded_text(child, depth + 1))
    elif isinstance(value, str):
        texts.append(value)
        candidate = value.strip()
        if len(candidate) >= 16 and len(candidate) <= 200000 and len(candidate) % 4 == 0 and re.fullmatch(r"[A-Za-z0-9+/=]+", candidate):
            try:
                decoded = base64.b64decode(candidate, validate=True)
                text = decoded.decode("utf-8", errors="ignore")
                if text:
                    texts.append(text)
                    try:
                        texts.extend(all_decoded_text(json.loads(text), depth + 1))
                    except Exception:
                        pass
            except Exception:
                pass
    return texts


def plan_summary(secret, source):
    if secret.get("missing"):
        return {"source": source, **secret}
    metadata = secret.get("metadata") or {}
    data = secret.get("data") or {}
    encoded_plan = data.get("plan") or ""
    raw = b""
    plan = None
    decode_error = None
    try:
        raw = base64.b64decode(encoded_plan)
        plan = json.loads(raw.decode("utf-8"))
    except Exception as exc:
        decode_error = f"{type(exc).__name__}: {exc}"
    text_corpus = "\n".join(all_decoded_text(plan)) if plan is not None else ""
    explicit_types = []
    for match in re.finditer(r"INSTALL_RKE2_TYPE\s*=\s*([A-Za-z0-9_-]+)", text_corpus):
        explicit_types.append(match.group(1).lower())
    instruction_names = []
    if isinstance(plan, dict):
        for instruction in plan.get("instructions") or []:
            if isinstance(instruction, dict):
                instruction_names.append(instruction.get("name"))
    return {
        "source": source,
        "metadata": {
            "namespace": metadata.get("namespace"),
            "name": metadata.get("name"),
            "uid": metadata.get("uid"),
            "resourceVersion": metadata.get("resourceVersion"),
            "creationTimestamp": metadata.get("creationTimestamp"),
            "ownerReferences": sanitize(metadata.get("ownerReferences") or []),
            "labels": sanitize(metadata.get("labels") or {}, "$.metadata.labels"),
            "annotations": sanitize(metadata.get("annotations") or {}, "$.metadata.annotations"),
        },
        "dataKeys": sorted(data.keys()),
        "planBytes": len(raw),
        "planSha256": hashlib.sha256(raw).hexdigest() if raw else None,
        "decodeError": decode_error,
        "instructionNames": instruction_names,
        "explicitInstallRke2Types": sorted(set(explicit_types)),
        "containsInstallTypeAgent": "agent" in explicit_types,
        "containsInstallTypeServer": "server" in explicit_types,
        "containsControlplaneArgument": bool(re.search(r"(^|\s)--controlplane(\s|$)", text_corpus)),
        "containsEtcdArgument": bool(re.search(r"(^|\s)--etcd(\s|$)", text_corpus)),
        "containsWorkerArgument": bool(re.search(r"(^|\s)--worker(\s|$)", text_corpus)),
        "enablesRke2Agent": bool(re.search(r"systemctl[^\n]{0,120}enable[^\n]{0,120}rke2-agent", text_corpus, re.I)),
        "enablesRke2Server": bool(re.search(r"systemctl[^\n]{0,120}enable[^\n]{0,120}rke2-server", text_corpus, re.I)),
    }


object_files = [
    ("capi-sen1.json", "CAPI Machine sen1"),
    ("capi-sen2.json", "CAPI Machine sen2"),
    ("capi-sen3.json", "CAPI Machine sen3"),
    ("custom-sen1.json", "CustomMachine sen1"),
    ("custom-sen2.json", "CustomMachine sen2"),
    ("custom-sen3.json", "CustomMachine sen3"),
    ("bootstrap-sen1.json", "RKEBootstrap sen1"),
    ("bootstrap-sen2.json", "RKEBootstrap sen2"),
    ("bootstrap-sen3.json", "RKEBootstrap sen3"),
    ("rke-control-plane.json", "RKEControlPlane local"),
    ("provisioning-cluster.json", "Provisioning Cluster local"),
    ("capi-cluster.json", "CAPI Cluster local"),
]

loaded = {name: load(name) for name, _ in object_files}
for name, label in object_files:
    print(f"===OBJECT:{label}===")
    print(json.dumps(object_summary(loaded[name], label), sort_keys=True, default=str))
    print(f"===ROLE-PATHS:{label}===")
    print(json.dumps(role_values(loaded[name]), sort_keys=True, default=str))

plan_files = [
    ("plan-sen1.json", "Machine plan sen1"),
    ("plan-sen2.json", "Machine plan sen2"),
    ("plan-sen3.json", "Machine plan sen3"),
]
plan_summaries = {}
for name, label in plan_files:
    summary = plan_summary(load(name), label)
    plan_summaries[name] = summary
    print(f"===PLAN:{label}===")
    print(json.dumps(summary, sort_keys=True, default=str))

print("===NODES===")
nodes = load("nodes.json")
node_summary = []
for item in nodes.get("items") or []:
    metadata = item.get("metadata") or {}
    labels = metadata.get("labels") or {}
    conditions = {
        condition.get("type"): condition.get("status")
        for condition in (item.get("status") or {}).get("conditions") or []
        if isinstance(condition, dict)
    }
    node_summary.append(
        {
            "name": metadata.get("name"),
            "uid": metadata.get("uid"),
            "resourceVersion": metadata.get("resourceVersion"),
            "ready": conditions.get("Ready"),
            "roleLabels": {
                key: value
                for key, value in labels.items()
                if "role" in key or "control-plane" in key or "etcd" in key or "worker" in key
            },
        }
    )
print(json.dumps(node_summary, sort_keys=True, default=str))

print("===FILTERED-EVENTS===")
events = load("events.json")
filtered_events = []
for item in events.get("items") or []:
    involved = item.get("involvedObject") or {}
    message = str(item.get("message") or "")
    name = str(involved.get("name") or "")
    if name not in TARGET_NAMES and not any(target in message for target in TARGET_NAMES):
        continue
    metadata = item.get("metadata") or {}
    filtered_events.append(
        {
            "namespace": metadata.get("namespace"),
            "name": metadata.get("name"),
            "firstTimestamp": item.get("firstTimestamp"),
            "lastTimestamp": item.get("lastTimestamp"),
            "eventTime": item.get("eventTime"),
            "count": item.get("count"),
            "type": item.get("type"),
            "reason": item.get("reason"),
            "reportingController": item.get("reportingController"),
            "source": sanitize(item.get("source") or {}),
            "involvedObject": sanitize(involved),
            "message": sanitize(message),
        }
    )
filtered_events.sort(key=lambda event: str(event.get("lastTimestamp") or event.get("eventTime") or ""))
print(json.dumps(filtered_events[-300:], sort_keys=True, default=str))

sen2_machine = loaded["capi-sen2.json"]
sen2_managers = []
for entry in managed_field_summary(sen2_machine):
    paths = entry.get("roleRelevantPaths") or []
    if any(
        path.endswith("rke.cattle.io/control-plane-role")
        or path.endswith("rke.cattle.io/etcd-role")
        or path.endswith("rke.cattle.io/worker-role")
        or path.endswith("cluster.x-k8s.io/control-plane")
        for path in paths
    ):
        sen2_managers.append(entry)

assessment = {
    "sen2CapiMachineRoleLabels": sanitize((sen2_machine.get("metadata") or {}).get("labels") or {}),
    "sen2CapiMachineRoleFieldManagers": sen2_managers,
    "sen2CustomMachineRolePaths": role_values(loaded["custom-sen2.json"]),
    "sen2RkeBootstrapRolePaths": role_values(loaded["bootstrap-sen2.json"]),
    "rkeControlPlaneRolePaths": role_values(loaded["rke-control-plane.json"]),
    "provisioningClusterRolePaths": role_values(loaded["provisioning-cluster.json"]),
    "sen2Plan": plan_summaries["plan-sen2.json"],
    "sen3Plan": plan_summaries["plan-sen3.json"],
    "clusterStateModified": False,
    "credentialValuesWrittenToEvidence": False,
    "productionReleaseApproved": False,
}
print("===ROLE-SOURCE-ASSESSMENT===")
print(json.dumps(assessment, sort_keys=True, default=str))
print("===DIAGNOSTIC-COMPLETE===")
PY
