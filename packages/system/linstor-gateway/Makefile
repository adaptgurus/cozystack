export NAME=linstor-gateway
export NAMESPACE=cozy-linstor

include ../../../hack/common-envs.mk
include ../../../hack/package.mk

LINSTOR_GATEWAY_VERSION ?= 2.3.0
LINSTOR_GATEWAY_SHA256 ?= a5cd30cc79941d8cbf742b1539a57eefa33d5a001f3b26ef671ff027f2c8e4ef

.PHONY: image image-linstor-gateway test

image: image-linstor-gateway

image-linstor-gateway:
	docker buildx build images/linstor-gateway \
		--build-arg LINSTOR_GATEWAY_VERSION=$(LINSTOR_GATEWAY_VERSION) \
		--build-arg LINSTOR_GATEWAY_SHA256=$(LINSTOR_GATEWAY_SHA256) \
		$(call image-tags,linstor-gateway,$(LINSTOR_GATEWAY_VERSION)) \
		$(call cache-args,linstor-gateway) \
		--metadata-file images/linstor-gateway.json \
		$(BUILDX_ARGS)
	REPOSITORY="$(REGISTRY)/linstor-gateway" \
		yq -i '.image.repository = strenv(REPOSITORY)' values.yaml
	TAG="$(IMAGE_TAG)@$$(yq e '."containerimage.digest"' images/linstor-gateway.json -o json -r)" \
		yq -i '.image.tag = strenv(TAG)' values.yaml
	rm -f images/linstor-gateway.json

test:
	helm template test . --set enabled=true >/dev/null
