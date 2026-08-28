NAME=vm-template-controller
NAMESPACE=cozy-system

include ../../../hack/common-envs.mk
include ../../../hack/package.mk

.PHONY: test image image-vm-template-controller

test:
	helm lint . --set vmTemplateController.image=example.invalid/vm-template-controller:test

image: image-vm-template-controller

image-vm-template-controller:
	docker buildx build -f images/vm-template-controller/Dockerfile ../../.. \
		$(call image-tags,vm-template-controller,v$(COZYSTACK_VERSION)) \
		$(call cache-args,vm-template-controller) \
		--metadata-file images/vm-template-controller.json \
		$(BUILDX_ARGS)
	IMAGE="$(REGISTRY)/vm-template-controller:$(IMAGE_TAG)@$$(yq e '."containerimage.digest"' images/vm-template-controller.json -o json -r)" \
		yq -i '.vmTemplateController.image = strenv(IMAGE)' values.yaml
	rm -f images/vm-template-controller.json
