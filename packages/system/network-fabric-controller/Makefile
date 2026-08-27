NAME=network-fabric-controller
NAMESPACE=cozy-network-fabric-controller

include ../../../hack/common-envs.mk
include ../../../hack/package.mk

test:
	helm lint . --set networkFabricController.image=example.invalid/network-fabric-controller:test

image: image-network-fabric-controller

image-network-fabric-controller:
	docker buildx build -f images/network-fabric-controller/Dockerfile ../../.. \
		$(call image-tags,network-fabric-controller,v$(COZYSTACK_VERSION)) \
		$(call cache-args,network-fabric-controller) \
		--metadata-file images/network-fabric-controller.json \
		$(BUILDX_ARGS)
	IMAGE="$(REGISTRY)/network-fabric-controller:$(IMAGE_TAG)@$$(yq e '."containerimage.digest"' images/network-fabric-controller.json -o json -r)" \
		yq -i '.networkFabricController.image = strenv(IMAGE)' values.yaml
	rm -f images/network-fabric-controller.json
