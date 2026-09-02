#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

mode=${LAYERSENTRY_VERIFY_MODE:-}
for required in LAYERSENTRY_NODE_PASSWORD_B64; do
  if [ -z "${!required:-}" ]; then
    echo "LAYERSENTRY_RESUME_VERIFY_ERROR:missing-${required}"
    exit 81
  fi
done
if [ "$mode" != source ] && [ "$mode" != local ]; then
  echo 'LAYERSENTRY_RESUME_VERIFY_ERROR:invalid-mode'
  exit 82
fi

work=$(mktemp -d /tmp/layersentry-sen2-resume-verify.XXXXXX)
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

if [ "$mode" = source ]; then
  for required in \
    EXPECTED_CAPI_MACHINE_UID \
    EXPECTED_RKE_BOOTSTRAP_UID \
    EXPECTED_CUSTOM_MACHINE_UID \
    EXPECTED_PLAN_SECRET_UID \
    EXPECTED_CORRECTED_PLAN_SHA256 \
    EXPECTED_CORRECTED_PLAN_LAST_UPDATED; do
    if [ -z "${!required:-}" ]; then
      echo "LAYERSENTRY_RESUME_VERIFY_ERROR:missing-${required}"
      exit 83
    fi
  done

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
    echo 'LAYERSENTRY_RESUME_VERIFY_ERROR:kubectl-not-found'
    exit 84
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
    "capi": capi,
    "bootstrap": bootstrap,
    "custom": custom,
    "plan": plan,
}
expected_uids = {
    "capi": os.environ["EXPECTED_CAPI_MACHINE_UID"],
    "bootstrap": os.environ["EXPECTED_RKE_BOOTSTRAP_UID"],
    "custom": os.environ["EXPECTED_CUSTOM_MACHINE_UID"],
    "plan": os.environ["EXPECTED_PLAN_SECRET_UID"],
}
for key, obj in objects.items():
    actual = (obj.get("metadata") or {}).get("uid")
    if actual != expected_uids[key]:
        raise SystemExit(f"UID mismatch for {key}: {actual!r}")

worker = "rke.cattle.io/worker-role"
bad = {
    "cluster.x-k8s.io/control-plane",
    "rke.cattle.io/control-plane-role",
    "rke.cattle.io/etcd-role",
}
role_summary = {}
for key, obj in objects.items():
    labels = (obj.get("metadata") or {}).get("labels") or {}
    if labels.get(worker) != "true":
        raise SystemExit(f"{key} is missing the worker role")
    present_bad = sorted(label for label in bad if label in labels)
    if present_bad:
        raise SystemExit(f"{key} still contains server role labels: {present_bad}")
    role_summary[key] = {
        name: value
        for name, value in labels.items()
        if "role" in name or "control-plane" in name
    }

raw_plan = base64.b64decode((plan.get("data") or {}).get("plan") or "")
if not raw_plan:
    raise SystemExit("corrected plan payload is empty")
plan_sha = hashlib.sha256(raw_plan).hexdigest()
expected_sha = os.environ["EXPECTED_CORRECTED_PLAN_SHA256"]
if plan_sha != expected_sha:
    raise SystemExit(
        f"corrected plan hash changed: expected {expected_sha}, found {plan_sha}"
    )
annotations = (plan.get("metadata") or {}).get("annotations") or {}
last_updated = annotations.get("rke.cattle.io/plan-last-updated")
expected_last_updated = os.environ["EXPECTED_CORRECTED_PLAN_LAST_UPDATED"]
if last_updated != expected_last_updated:
    raise SystemExit(
        "corrected plan timestamp changed: "
        f"expected {expected_last_updated!r}, found {last_updated!r}"
    )

summary = {
    "target": "fleet-local/custom-81a2c5e94b13",
    "node": "sen2",
    "verificationMode": "already-corrected-read-only",
    "uids": expected_uids,
    "roles": role_summary,
    "correctedPlanSha256": plan_sha,
    "correctedPlanLastUpdated": last_updated,
    "sourceStateModified": False,
    "rke2DataDeleted": False,
    "vmDiskWiped": False,
    "vmReinstalled": False,
    "productionReleaseApproved": False,
}
print("LAYERSENTRY_RESUME_SOURCE_STATE=" + json.dumps(summary, sort_keys=True))
PY
  echo 'LAYERSENTRY_SEN2_CORRECTED_WORKER_SOURCE:PASS'
  exit 0
fi

hostname_value=$(hostname | tr -d '\r\n')
yq_path=$(command -v yq 2>/dev/null || true)
if [ -z "$yq_path" ]; then
  echo 'LAYERSENTRY_RESUME_VERIFY_ERROR:yq-not-found'
  exit 91
fi
role=$(sudo -n "$yq_path" e -r '.role // ""' /etc/rancher/rancherd/config.yaml 2>/dev/null | tail -n 1 | tr -d '\r\n' || true)
server_url=$(sudo -n "$yq_path" e -r '.server // ""' /etc/rancher/rancherd/config.yaml 2>/dev/null | tail -n 1 | tr -d '\r\n' || true)
install_mode=$(sudo -n "$yq_path" e -r '.install.mode // ""' /oem/harvester.config 2>/dev/null | tail -n 1 | tr -d '\r\n' || true)
plan_type=$(sudo -n awk -F= '$1 == "INSTALL_RKE2_TYPE" { print $2 }' /var/lib/rancher/rke2/system-agent-installer/rke2-sa.env 2>/dev/null | tail -n 1 | tr -d '\r\n' || true)
server_enabled=$(sudo -n systemctl is-enabled rke2-server.service 2>&1 | tail -n 1 | tr -d '\r\n' || true)
server_active=$(sudo -n systemctl is-active rke2-server.service 2>&1 | tail -n 1 | tr -d '\r\n' || true)
agent_enabled=$(sudo -n systemctl is-enabled rke2-agent.service 2>&1 | tail -n 1 | tr -d '\r\n' || true)
agent_active=$(sudo -n systemctl is-active rke2-agent.service 2>&1 | tail -n 1 | tr -d '\r\n' || true)
system_agent_active=$(sudo -n systemctl is-active rancher-system-agent.service 2>&1 | tail -n 1 | tr -d '\r\n' || true)
kubelet_open=false
if timeout 3 bash -c '</dev/tcp/127.0.0.1/10250' >/dev/null 2>&1; then
  kubelet_open=true
fi
agent_process=false
if ps -ef | grep -E '[r]ke2[[:space:]]+agent' >/dev/null 2>&1; then
  agent_process=true
fi
server_process=false
if ps -ef | grep -E '[r]ke2[[:space:]]+server' >/dev/null 2>&1; then
  server_process=true
fi
if [ "$plan_type" = agent ]; then
  evidence_mode=installer-env
else
  evidence_mode=runtime-role-fallback
fi
printf 'LAYERSENTRY_RESUME_LOCAL_STATE:hostname=%s;role=%s;serverUrl=%s;installMode=%s;planType=%s;serverEnabled=%s;serverActive=%s;agentEnabled=%s;agentActive=%s;systemAgentActive=%s;kubelet10250=%s;agentProcess=%s;serverProcess=%s;evidenceMode=%s\n' \
  "$hostname_value" "$role" "$server_url" "$install_mode" "$plan_type" \
  "$server_enabled" "$server_active" "$agent_enabled" "$agent_active" \
  "$system_agent_active" "$kubelet_open" "$agent_process" "$server_process" \
  "$evidence_mode"

if [ "$hostname_value" != sen2 ]; then exit 92; fi
if [ "$role" != agent ]; then exit 93; fi
if [ "$server_url" != 'https://10.10.10.10:443' ]; then exit 94; fi
if [ "$install_mode" != join ]; then exit 95; fi
if [ -n "$plan_type" ] && [ "$plan_type" != agent ]; then exit 96; fi
if [ "$server_active" = active ] || [ "$server_active" = activating ]; then exit 97; fi
if [ "$agent_enabled" != enabled ]; then exit 98; fi
if [ "$agent_active" != active ]; then exit 99; fi
if [ "$system_agent_active" != active ]; then exit 100; fi
if [ "$kubelet_open" != true ]; then exit 101; fi
if [ "$agent_process" != true ]; then exit 102; fi
if [ "$server_process" != false ]; then exit 103; fi

echo 'LAYERSENTRY_SEN2_LOCAL_WORKER_STATE:PASS'
