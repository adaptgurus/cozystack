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
    echo "LAYERSENTRY_SOURCE_VERIFY_ERROR:missing-${required}"
    exit 81
  fi
done

work=$(mktemp -d /tmp/layersentry-sen2-source-current.XXXXXX)
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
    kubectl_path=$candidate
    break
  fi
done
if [ -z "$kubectl_path" ]; then
  echo 'LAYERSENTRY_SOURCE_VERIFY_ERROR:kubectl-not-found'
  exit 82
fi

kubeconfig=/etc/rancher/rke2/rke2.yaml
k() {
  sudo -n "$kubectl_path" --kubeconfig "$kubeconfig" "$@"
}

machine=custom-81a2c5e94b13
k -n fleet-local get machines.cluster.x-k8s.io "$machine" -o json > "$work/capi.json"
k -n fleet-local get rkebootstraps.rke.cattle.io "$machine" -o json > "$work/bootstrap.json"
k -n fleet-local get custommachines.rke.cattle.io "$machine" -o json > "$work/custom.json"
k -n fleet-local get secret "$machine-machine-plan" -o json > "$work/plan.json"

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

capi = load("capi.json")
bootstrap = load("bootstrap.json")
custom = load("custom.json")
plan = load("plan.json")
objects = {
    "capiMachine": capi,
    "rkeBootstrap": bootstrap,
    "customMachine": custom,
    "planSecret": plan,
}
expected_uids = {
    "capiMachine": os.environ["EXPECTED_CAPI_MACHINE_UID"],
    "rkeBootstrap": os.environ["EXPECTED_RKE_BOOTSTRAP_UID"],
    "customMachine": os.environ["EXPECTED_CUSTOM_MACHINE_UID"],
    "planSecret": os.environ["EXPECTED_PLAN_SECRET_UID"],
}
for name, obj in objects.items():
    actual = (obj.get("metadata") or {}).get("uid")
    if actual != expected_uids[name]:
        raise SystemExit(
            f"authoritative object UID mismatch for {name}: "
            f"expected {expected_uids[name]!r}, found {actual!r}"
        )

worker = "rke.cattle.io/worker-role"
server_labels = {
    "cluster.x-k8s.io/control-plane",
    "rke.cattle.io/control-plane-role",
    "rke.cattle.io/etcd-role",
}
role_summary = {}
for name, obj in objects.items():
    labels = (obj.get("metadata") or {}).get("labels") or {}
    if labels.get(worker) != "true":
        raise SystemExit(f"{name} does not retain worker-role=true")
    conflicting = sorted(label for label in server_labels if label in labels)
    if conflicting:
        raise SystemExit(
            f"{name} regained conflicting server role labels: {conflicting}"
        )
    role_summary[name] = {
        key: value
        for key, value in labels.items()
        if "role" in key or "control-plane" in key
    }

raw_plan = base64.b64decode((plan.get("data") or {}).get("plan") or "")
if not raw_plan:
    raise SystemExit("current worker plan payload is empty")
plan_sha = hashlib.sha256(raw_plan).hexdigest()
old_sha = os.environ["EXPECTED_OLD_PLAN_SHA256"]
if plan_sha == old_sha:
    raise SystemExit("current plan reverted to the evidenced failing server plan")
annotations = (plan.get("metadata") or {}).get("annotations") or {}
last_updated = annotations.get("rke.cattle.io/plan-last-updated")

summary = {
    "target": "fleet-local/custom-81a2c5e94b13",
    "node": "sen2",
    "verificationMode": "current-read-only-worker-source",
    "uids": expected_uids,
    "roles": role_summary,
    "oldFailingPlanSha256": old_sha,
    "currentPlanSha256": plan_sha,
    "currentPlanLastUpdated": last_updated,
    "currentPlanDiffersFromFailingPlan": True,
    "authoritativeSourceModified": False,
    "rke2DataDeleted": False,
    "vmDiskWiped": False,
    "vmReinstalled": False,
    "productionReleaseApproved": False,
}
print("LAYERSENTRY_CURRENT_WORKER_SOURCE=" + json.dumps(summary, sort_keys=True))
PY

echo 'LAYERSENTRY_SEN2_CURRENT_WORKER_SOURCE:PASS'
