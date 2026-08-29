export NAME=kubevirt
export NAMESPACE=cozy-$(NAME)

include ../../../hack/package.mk

test:
	helm unittest .
	./tests/update_idempotency_test.sh

# File the parameterization patches are applied to. Overridable so the
# idempotency test can drive `update` against a throwaway copy instead of the
# in-tree CR.
CR_FILE ?= templates/kubevirt-cr.yaml

# Re-apply the Cozystack-specific parameterization on top of the in-tree
# templates/kubevirt-cr.yaml. This target does NOT download anything from
# upstream — the live KubeVirt CR distributed by upstream is a near-empty
# stub and cannot stand in for the in-tree file, which carries deliberately
# curated Cozystack production settings.
#
# KubeVirt v1.8.4 feature-gate rule:
#   * GA gates (LiveMigration, AutoResourceLimitsGate, GPU) are always active
#     and MUST NOT be re-added to developerConfiguration.featureGates.
#   * The static list in the in-tree CR contains only capabilities that are
#     still non-GA in v1.8.4 and therefore remain subject to CI/lab evidence.
#
# To refresh from a newer upstream KubeVirt:
#   1. Inspect the upstream release notes and feature-gate lifecycle changes.
#   2. Hand-merge schema/spec changes into templates/kubevirt-cr.yaml.
#   3. Preserve the production safety invariants checked at the end of this
#      target (uninstall protection, TLS pre-copy migration and no automatic
#      eviction/disruptive migration fallback).
#   4. Run `make update` and the full KubeVirt production CI gate.
#
# GNU sed is required — on macOS run under a Linux container or via gsed.
update:
	@test -f $(CR_FILE) || { echo "ERROR: $(CR_FILE) not found — drop a hand-merged upstream CR there first" >&2; exit 1; }
	@# Idempotent — each sed only inserts if the matching Cozystack patch
	@# isn't already present in the file.
	grep -q '^  namespace: cozy-kubevirt$$' $(CR_FILE) || sed -i 's/namespace: kubevirt/namespace: cozy-kubevirt/g' $(CR_FILE)
	grep -q '{{- if .Values.cpuAllocationRatio }}' $(CR_FILE) || sed -i '/^    developerConfiguration:$$/a\      {{- if .Values.cpuAllocationRatio }}\n      cpuAllocationRatio: {{ .Values.cpuAllocationRatio }}\n      {{- end }}' $(CR_FILE)
	grep -q '{{- range .Values.extraFeatureGates }}' $(CR_FILE) || sed -i '/^      - VMExport$$/a\      {{- range .Values.extraFeatureGates }}\n      - {{ . }}\n      {{- end }}' $(CR_FILE)
	@# permittedHostDevices and mediatedDevicesConfiguration are guarded
	@# independently: a hand-merge may drop one while keeping the other, and
	@# each must self-heal on its own.
	grep -q '{{- with .Values.permittedHostDevices }}' $(CR_FILE) || sed -i '/^    evictionStrategy:/i\    {{- with .Values.permittedHostDevices }}\n    permittedHostDevices:\n      {{- toYaml . | nindent 6 }}\n    {{- end }}' $(CR_FILE)
	grep -q '{{- with .Values.mediatedDevicesConfiguration }}' $(CR_FILE) || sed -i '/^    evictionStrategy:/i\    {{- with .Values.mediatedDevicesConfiguration }}\n    mediatedDevicesConfiguration:\n      {{- toYaml . | nindent 6 }}\n    {{- end }}' $(CR_FILE)
	@# Parameterization sanity checks. If a hand-merge moved/renamed an anchor,
	@# fail rather than silently ship a partially parameterized KubeVirt CR.
	@grep -q '{{- if .Values.cpuAllocationRatio }}' $(CR_FILE) || { echo "ERROR: directive '{{- if .Values.cpuAllocationRatio }}' not inserted — restore the 'developerConfiguration:' anchor in $(CR_FILE) and re-run" >&2; exit 1; }
	@grep -q '{{- range .Values.extraFeatureGates }}' $(CR_FILE) || { echo "ERROR: directive '{{- range .Values.extraFeatureGates }}' not inserted — restore the '- VMExport' anchor in $(CR_FILE) and re-run" >&2; exit 1; }
	@grep -q '{{- with .Values.permittedHostDevices }}' $(CR_FILE) || { echo "ERROR: directive '{{- with .Values.permittedHostDevices }}' not inserted — restore the 'evictionStrategy:' anchor in $(CR_FILE) and re-run" >&2; exit 1; }
	@grep -q '{{- with .Values.mediatedDevicesConfiguration }}' $(CR_FILE) || { echo "ERROR: directive '{{- with .Values.mediatedDevicesConfiguration }}' not inserted — restore the 'evictionStrategy:' anchor in $(CR_FILE) and re-run" >&2; exit 1; }
	@# Production safety invariants are intentionally fail-closed. Unlike the
	@# parameterization above these are never silently manufactured during an
	@# upstream refresh; a maintainer must consciously preserve/review them.
	@grep -q '^  uninstallStrategy: BlockUninstallIfWorkloadsExist$$' $(CR_FILE) || { echo "ERROR: KubeVirt uninstall workload protection is missing" >&2; exit 1; }
	@grep -q '^      disableTLS: false$$' $(CR_FILE) || { echo "ERROR: live-migration TLS protection is not explicitly enabled" >&2; exit 1; }
	@grep -q '^      allowAutoConverge: false$$' $(CR_FILE) || { echo "ERROR: automatic migration convergence must remain disabled by default" >&2; exit 1; }
	@grep -q '^      allowPostCopy: false$$' $(CR_FILE) || { echo "ERROR: post-copy migration must remain disabled by default" >&2; exit 1; }
	@grep -q '^      allowWorkloadDisruption: false$$' $(CR_FILE) || { echo "ERROR: disruptive migration fallback must remain disabled by default" >&2; exit 1; }
	@grep -q '^      unsafeMigrationOverride: false$$' $(CR_FILE) || { echo "ERROR: unsafe migration override must remain disabled" >&2; exit 1; }
	@if grep -q '^    - Evict$$' $(CR_FILE); then echo "ERROR: automatic Evict fallback would shut down non-live-migratable VMs during KubeVirt upgrades" >&2; exit 1; fi
