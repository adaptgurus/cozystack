#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

for required in \
  LAYERSENTRY_NODE_PASSWORD_B64 \
  EXPECTED_CAPI_MACHINE_UID \
  EXPECTED_RKE_BOOTSTRAP_UID \
  EXPECTED_CUSTOM_MACHINE_UID \
  EXPECTED_PLAN_SECRET_UID \
  EXPECTED_OLD_PLAN_SHA256; do
  if [ -z "${!required:-}" ]; then
    echo "LAYERSENTRY_WORKER_PLAN_ERROR:missing-${required}"
    exit 81
  fi
done

work=$(mktemp -d /tmp/layersentry-sen2-worker-plan.XXXXXX)
committed=false
capi_patched=false
bootstrap_patched=false

find_kubectl() {
  local candidate
  for candidate in \
    /var/lib/rancher/rke2/bin/kubectl \
    /opt/rke2/bin/kubectl \
    /usr/local/bin/kubectl \
    /usr/bin/kubectl; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

kubectl_path=''
kubeconfig=/etc/rancher/rke2/rke2.yaml
k() {
  sudo -n "$kubectl_path" --kubeconfig "$kubeconfig" "$@"
}

rollback() {
  set +e
  echo 'LAYERSENTRY_WORKER_PLAN_ROLLBACK:begin'
  if [ "$bootstrap_patched" = true ]; then
    k -n fleet-local label rkebootstraps.rke.cattle.io custom-81a2c5e94b13 \
      rke.cattle.io/control-plane-role=true \
      rke.cattle.io/etcd-role=true \
      rke.cattle.io/worker-role=true \
      --overwrite >/dev/null 2>&1 || true
  fi
  if [ "$capi_patched" = true ]; then
    k -n fleet-local label machines.cluster.x-k8s.io custom-81a2c5e94b13 \
      cluster.x-k8s.io/control-plane=true \
      rke.cattle.io/control-plane-role=true \
      rke.cattle.io/etcd-role=true \
      rke.cattle.io/worker-role=true \
      --overwrite >/dev/null 2>&1 || true
  fi
  echo 'LAYERSENTRY_WORKER_PLAN_ROLLBACK:end'
}

finish() {
  local rc=$?
  trap - EXIT HUP INT TERM
  if [ "$rc" -ne 0 ] && [ "$committed" != true ]; then
    rollback
  fi
  rm -rf "$work"
  exit "$rc"
}
trap finish EXIT HUP INT TERM

printf '%s' "$LAYERSENTRY_NODE_PASSWORD_B64" | base64 -d > "$work/node-password"
printf '\n' >> "$work/node-password"
chmod 0600 "$work/node-password"
unset LAYERSENTRY_NODE_PASSWORD_B64
if ! sudo -n true >/dev/null 2>&1; then
  sudo -S -p '' -v < "$work/node-password"
fi

kubectl_path=$(find_kubectl) || {
  echo 'LAYERSENTRY_WORKER_PLAN_ERROR:kubectl-not-found'
  exit 82
}

machine=custom-81a2c5e94b13
capture_state() {
  local prefix=$1
  k -n fleet-local get machines.cluster.x-k8s.io "$machine" --show-managed-fields -o json > "$work/${prefix}-capi.json"
  k -n fleet-local get rkebootstraps.rke.cattle.io "$machine" --show-managed-fields -o json > "$work/${prefix}-bootstrap.json"
  k -n fleet-local get custommachines.rke.cattle.io "$machine" --show-managed-fields -o json > "$work/${prefix}-custom.json"
  k -n fleet-local get secret "$machine-machine-plan" -o json > "$work/${prefix}-plan.json"
  if k -n local get secret "$machine" -o json > "$work/${prefix}-owner-secret.json" 2>/dev/null; then
    :
  else
    printf '{"missing":true}\n' > "$work/${prefix}-owner-secret.json"
  fi
}

capture_state pre

python3 - "$work" <<'PY'
import base64
import hashlib
import json
import os
import sys
from pathlib import Path

root = Path(sys.argv[1])

def load(name):
    return json.loads((root / name).read_text(encoding="utf-8"))

capi = load("pre-capi.json")
bootstrap = load("pre-bootstrap.json")
custom = load("pre-custom.json")
plan = load("pre-plan.json")
owner = load("pre-owner-secret.json")

expected = {
    "capi": os.environ["EXPECTED_CAPI_MACHINE_UID"],
    "bootstrap": os.environ["EXPECTED_RKE_BOOTSTRAP_UID"],
    "custom": os.environ["EXPECTED_CUSTOM_MACHINE_UID"],
    "plan": os.environ["EXPECTED_PLAN_SECRET_UID"],
}
objects = {"capi": capi, "bootstrap": bootstrap, "custom": custom, "plan": plan}
for key, obj in objects.items():
    actual = (obj.get("metadata") or {}).get("uid")
    if actual != expected[key]:
        raise SystemExit(f"preflight UID mismatch for {key}: {actual!r}")

bad = {
    "cluster.x-k8s.io/control-plane": "true",
    "rke.cattle.io/control-plane-role": "true",
    "rke.cattle.io/etcd-role": "true",
}
worker = "rke.cattle.io/worker-role"
for name, obj in (("CAPI Machine", capi), ("RKEBootstrap", bootstrap)):
    labels = (obj.get("metadata") or {}).get("labels") or {}
    if labels.get(worker) != "true":
        raise SystemExit(f"{name} is missing the worker role")
    for key, value in bad.items():
        if key == "cluster.x-k8s.io/control-plane" and name == "RKEBootstrap":
            continue
        if labels.get(key) != value:
            raise SystemExit(f"{name} no longer has expected erroneous label {key}")

custom_labels = (custom.get("metadata") or {}).get("labels") or {}
if custom_labels.get(worker) != "true":
    raise SystemExit("CustomMachine is not worker-only")
for key in bad:
    if key in custom_labels:
        raise SystemExit(f"CustomMachine unexpectedly has server role label {key}")

plan_labels = (plan.get("metadata") or {}).get("labels") or {}
if plan_labels.get(worker) != "true":
    raise SystemExit("plan secret is missing the worker role")
if plan_labels.get("rke.cattle.io/control-plane-role") != "true" or plan_labels.get("rke.cattle.io/etcd-role") != "true":
    raise SystemExit("plan secret no longer matches the expected failing server plan")

raw_plan = base64.b64decode((plan.get("data") or {}).get("plan") or "")
plan_sha = hashlib.sha256(raw_plan).hexdigest()
if plan_sha != os.environ["EXPECTED_OLD_PLAN_SHA256"]:
    raise SystemExit(f"failing plan hash changed before correction: {plan_sha}")
if not owner.get("missing"):
    raise SystemExit("transient MachineRequest owner Secret unexpectedly still exists")

role_managers = []
for resource, obj in (("capi", capi), ("bootstrap", bootstrap)):
    for entry in (obj.get("metadata") or {}).get("managedFields") or []:
        fields = json.dumps(entry.get("fieldsV1") or {}, sort_keys=True)
        if "control-plane-role" in fields or "etcd-role" in fields or "control-plane" in fields:
            role_managers.append({
                "resource": resource,
                "manager": entry.get("manager"),
                "operation": entry.get("operation"),
                "time": entry.get("time"),
            })
if not any(item.get("manager") == "kubectl-label" for item in role_managers):
    raise SystemExit("managed fields no longer attribute erroneous server roles to kubectl-label")

summary = {
    "target": "fleet-local/custom-81a2c5e94b13",
    "node": "sen2",
    "capiMachineUid": expected["capi"],
    "rkeBootstrapUid": expected["bootstrap"],
    "customMachineUid": expected["custom"],
    "planSecretUid": expected["plan"],
    "oldPlanSha256": plan_sha,
    "oldPlanLastUpdated": ((plan.get("metadata") or {}).get("annotations") or {}).get("rke.cattle.io/plan-last-updated"),
    "erroneousRoleFieldManagers": role_managers,
    "customMachineWorkerOnly": True,
    "ownerSecretPresent": False,
    "clusterStateModified": False,
    "productionReleaseApproved": False,
}
print("LAYERSENTRY_WORKER_PLAN_PREFLIGHT=" + json.dumps(summary, sort_keys=True))

capi_patch = [
    {"op": "test", "path": "/metadata/uid", "value": expected["capi"]},
    {"op": "test", "path": "/metadata/labels/rke.cattle.io~1worker-role", "value": "true"},
    {"op": "test", "path": "/metadata/labels/cluster.x-k8s.io~1control-plane", "value": "true"},
    {"op": "test", "path": "/metadata/labels/rke.cattle.io~1control-plane-role", "value": "true"},
    {"op": "test", "path": "/metadata/labels/rke.cattle.io~1etcd-role", "value": "true"},
    {"op": "remove", "path": "/metadata/labels/cluster.x-k8s.io~1control-plane"},
    {"op": "remove", "path": "/metadata/labels/rke.cattle.io~1control-plane-role"},
    {"op": "remove", "path": "/metadata/labels/rke.cattle.io~1etcd-role"},
]
bootstrap_patch = [
    {"op": "test", "path": "/metadata/uid", "value": expected["bootstrap"]},
    {"op": "test", "path": "/metadata/labels/rke.cattle.io~1worker-role", "value": "true"},
    {"op": "test", "path": "/metadata/labels/rke.cattle.io~1control-plane-role", "value": "true"},
    {"op": "test", "path": "/metadata/labels/rke.cattle.io~1etcd-role", "value": "true"},
    {"op": "remove", "path": "/metadata/labels/rke.cattle.io~1control-plane-role"},
    {"op": "remove", "path": "/metadata/labels/rke.cattle.io~1etcd-role"},
]
(root / "capi-patch.json").write_text(json.dumps(capi_patch), encoding="utf-8")
(root / "bootstrap-patch.json").write_text(json.dumps(bootstrap_patch), encoding="utf-8")
PY

k -n fleet-local patch rkebootstraps.rke.cattle.io "$machine" \
  --type=json --patch-file "$work/bootstrap-patch.json" >/dev/null
bootstrap_patched=true
k -n fleet-local patch machines.cluster.x-k8s.io "$machine" \
  --type=json --patch-file "$work/capi-patch.json" >/dev/null
capi_patched=true

echo 'LAYERSENTRY_WORKER_PLAN_PATCHES_APPLIED'

old_plan_sha=$EXPECTED_OLD_PLAN_SHA256
converged=false
for attempt in $(seq 1 60); do
  capture_state post
  if python3 - "$work" "$old_plan_sha" <<'PY'
import base64
import hashlib
import json
import os
import sys
from pathlib import Path

root = Path(sys.argv[1])
old_sha = sys.argv[2]

def load(name):
    return json.loads((root / name).read_text(encoding="utf-8"))

capi = load("post-capi.json")
bootstrap = load("post-bootstrap.json")
custom = load("post-custom.json")
plan = load("post-plan.json")
expected = {
    "capi": os.environ["EXPECTED_CAPI_MACHINE_UID"],
    "bootstrap": os.environ["EXPECTED_RKE_BOOTSTRAP_UID"],
    "custom": os.environ["EXPECTED_CUSTOM_MACHINE_UID"],
    "plan": os.environ["EXPECTED_PLAN_SECRET_UID"],
}
for key, obj in (("capi", capi), ("bootstrap", bootstrap), ("custom", custom), ("plan", plan)):
    if (obj.get("metadata") or {}).get("uid") != expected[key]:
        raise SystemExit(1)

worker = "rke.cattle.io/worker-role"
bad = {
    "cluster.x-k8s.io/control-plane",
    "rke.cattle.io/control-plane-role",
    "rke.cattle.io/etcd-role",
}
for obj in (capi, bootstrap, custom, plan):
    labels = (obj.get("metadata") or {}).get("labels") or {}
    if labels.get(worker) != "true":
        raise SystemExit(1)
    if any(key in labels for key in bad):
        raise SystemExit(1)

raw_plan = base64.b64decode((plan.get("data") or {}).get("plan") or "")
new_sha = hashlib.sha256(raw_plan).hexdigest()
if not raw_plan or new_sha == old_sha:
    raise SystemExit(1)

summary = {
    "capiMachineRoles": {k: v for k, v in ((capi.get("metadata") or {}).get("labels") or {}).items() if "role" in k or "control-plane" in k},
    "rkeBootstrapRoles": {k: v for k, v in ((bootstrap.get("metadata") or {}).get("labels") or {}).items() if "role" in k or "control-plane" in k},
    "customMachineRoles": {k: v for k, v in ((custom.get("metadata") or {}).get("labels") or {}).items() if "role" in k or "control-plane" in k},
    "planSecretRoles": {k: v for k, v in ((plan.get("metadata") or {}).get("labels") or {}).items() if "role" in k or "control-plane" in k},
    "newPlanSha256": new_sha,
    "planChanged": True,
    "planLastUpdated": ((plan.get("metadata") or {}).get("annotations") or {}).get("rke.cattle.io/plan-last-updated"),
    "preTerminateHookPresent": "pre-terminate.delete.hook.machine.cluster.x-k8s.io/rke-bootstrap-cleanup" in ((capi.get("metadata") or {}).get("annotations") or {}),
    "clusterStateModified": True,
    "sourceRoleCorrectionCommitted": True,
    "productionReleaseApproved": False,
}
print("LAYERSENTRY_WORKER_PLAN_CONVERGED=" + json.dumps(summary, sort_keys=True))
PY
  then
    converged=true
    break
  fi
  echo "LAYERSENTRY_WORKER_PLAN_WAIT:${attempt}/60"
  sleep 5
done

if [ "$converged" != true ]; then
  echo 'LAYERSENTRY_WORKER_PLAN_ERROR:controller-plan-did-not-converge'
  exit 83
fi

committed=true
echo 'LAYERSENTRY_SEN2_AUTHORITATIVE_WORKER_PLAN:PASS'
