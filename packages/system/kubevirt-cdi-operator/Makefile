export NAME=kubevirt-cdi-operator
export NAMESPACE=cozy-kubevirt-cdi

include ../../../hack/package.mk

# Keep CDI regeneration reproducible. The in-tree manifest is currently
# v1.64.0; do not follow releases/latest because that can silently change the
# virtualization stack during an unrelated package refresh. Upgrade only after
# compatibility and real-lab import/clone/upload validation.
CDI_VERSION ?= v1.64.0
CDI_OPERATOR_SHA256 ?= 9540acafd85ecf6523eb77c9759a24e6d02d7494e253baa6930a90f0b8fad63c

update:
	rm -rf templates
	mkdir templates
	@set -eu; \
		tmp=$$(mktemp); \
		trap 'rm -f "$$tmp"' EXIT; \
		wget -q --https-only "https://github.com/kubevirt/containerized-data-importer/releases/download/$(CDI_VERSION)/cdi-operator.yaml" -O "$$tmp"; \
		echo "$(CDI_OPERATOR_SHA256)  $$tmp" | sha256sum -c -; \
		mv "$$tmp" templates/cdi-operator.yaml; \
		trap - EXIT
	@grep -q 'image: quay.io/kubevirt/cdi-operator:$(CDI_VERSION)' templates/cdi-operator.yaml || { echo "ERROR: downloaded CDI operator manifest does not contain expected $(CDI_VERSION) image" >&2; exit 1; }
	sed -i 's/namespace: cdi/namespace: cozy-kubevirt-cdi/g' templates/cdi-operator.yaml
	awk -i inplace -v RS="---" '!/kind: Namespace/{printf "%s", $$0 RS}' templates/cdi-operator.yaml
	@# The patch records repo-root paths (a/packages/system/...); this Makefile
	@# executes from this package directory, so strip through the package prefix.
	patch --no-backup-if-mismatch --batch -p4 < patches/startupProbe.diff
