export NAME=kubevirt-operator
export NAMESPACE=cozy-kubevirt

include ../../../hack/package.mk

# Production pin. KubeVirt v1.7.x is intentionally skipped because of the
# live-migration regression tracked at kubevirt/kubevirt#16386. Any bump must
# update BOTH the version and the upstream release-asset SHA-256 after review.
KUBEVIRT_RELEASE ?= v1.8.4
KUBEVIRT_OPERATOR_SHA256 ?= d1d8264eec5b802c122bec6c54d8c3b11e119ee2a5c75602aaa8b53ea3857eda

update:
	@# Do not remove the whole templates directory: it also contains the
	@# Cozystack-local PrometheusRule. Refresh only the vendored upstream file.
	mkdir -p templates
	rm -f templates/kubevirt-operator.yaml
	@set -eu; \
		tmp=$$(mktemp); \
		trap 'rm -f "$$tmp"' EXIT; \
		wget -q --https-only "https://github.com/kubevirt/kubevirt/releases/download/$(KUBEVIRT_RELEASE)/kubevirt-operator.yaml" -O "$$tmp"; \
		echo "$(KUBEVIRT_OPERATOR_SHA256)  $$tmp" | sha256sum -c -; \
		mv "$$tmp" templates/kubevirt-operator.yaml; \
		trap - EXIT
	@grep -q 'image: quay.io/kubevirt/virt-operator:$(KUBEVIRT_RELEASE)' templates/kubevirt-operator.yaml || { echo "ERROR: downloaded KubeVirt operator manifest does not contain expected $(KUBEVIRT_RELEASE) image" >&2; exit 1; }
	sed -i 's/namespace: kubevirt/namespace: $(NAMESPACE)/g' templates/kubevirt-operator.yaml
	awk -i inplace -v RS="---" '!/kind: Namespace/{printf "%s", $$0 RS}' templates/kubevirt-operator.yaml
	@test -f templates/prometheusrule.yaml || { echo "ERROR: Cozystack KubeVirt PrometheusRule was lost during regeneration" >&2; exit 1; }
