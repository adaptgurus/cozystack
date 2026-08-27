NAME=vm-network-admission
NAMESPACE=cozy-system

include ../../../hack/common-envs.mk
include ../../../hack/package.mk

image: image-vm-network-admission

image-vm-network-admission:
	docker buildx build -f images/vm-network-admission/Dockerfile ../../.. \
		$(call image-tags,vm-network-admission,v$(COZYSTACK_VERSION)) \
		$(call cache-args,vm-network-admission) \
		--metadata-file images/vm-network-admission.json \
		$(BUILDX_ARGS)
	IMAGE="$(REGISTRY)/vm-network-admission:$(IMAGE_TAG)@$$(yq e '."containerimage.digest"' images/vm-network-admission.json -o json -r)" \
		yq -i '.image = strenv(IMAGE)' values.yaml
	rm -f images/vm-network-admission.json
