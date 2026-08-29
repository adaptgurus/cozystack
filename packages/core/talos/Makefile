NAME=talos
NAMESPACE=cozy-system

TALOS_VERSION=$(shell awk '/^version:/ {print $$2}' images/talos/profiles/installer.yaml)
BASE_INSTALLER_IMAGE?=ghcr.io/siderolabs/installer:$(TALOS_VERSION)
IMAGER_IMAGE?=ghcr.io/siderolabs/imager:$(TALOS_VERSION)

include ../../../hack/common-envs.mk

update:
	hack/gen-profiles.sh

layersentry-storage-server-extensions:
	mkdir -p ../../../_out/extensions
	sh hack/build-layersentry-iscsi-target-extension.sh ../../../_out/extensions
	sh hack/build-layersentry-nfs-server-extension.sh ../../../_out/extensions
	sh hack/build-layersentry-hci-tools-extension.sh ../../../_out/extensions
	test -s ../../../_out/extensions/layersentry-iscsi-target.tar
	test -s ../../../_out/extensions/layersentry-nfs-server.tar
	test -s ../../../_out/extensions/layersentry-hci-tools.tar

refresh-profiles: layersentry-storage-server-extensions
	BASE_INSTALLER_IMAGE="$(BASE_INSTALLER_IMAGE)" hack/gen-profiles.sh $(TALOS_VERSION)

image: image-matchbox image-talos

image-matchbox:
	docker buildx build images/matchbox \
		$(BUILDX_ARGS) \
		$(call image-tags,matchbox,$(MATCHBOX_VERSION))

image-talos:
	docker buildx build images/talos \
		$(BUILDX_ARGS) \
		$(call image-tags,talos,$(TALOS_VERSION))

assets: talos-iso talos-nocloud talos-metal talos-kernel talos-initramfs

talos-iso:
	test -f ../../../_out/assets/metal-amd64.iso || $(MAKE) build-talos-iso

talos-nocloud:
	test -f ../../../_out/assets/nocloud-amd64.raw.xz || $(MAKE) build-talos-nocloud

talos-metal:
	test -f ../../../_out/assets/metal-amd64.raw.xz || $(MAKE) build-talos-metal

talos-kernel:
	test -f ../../../_out/assets/vmlinuz-amd64 || $(MAKE) build-talos-kernel

talos-initramfs:
	test -f ../../../_out/assets/initramfs-amd64.xz || $(MAKE) build-talos-initramfs

build-talos-initramfs build-talos-kernel build-talos-installer build-talos-iso build-talos-nocloud build-talos-metal: refresh-profiles
	mkdir -p ../../../_out/assets
	cat images/talos/profiles/$(subst build-talos-,,$@).yaml | \
		docker run --rm -i \
			-v /dev:/dev \
			-v "$(abspath ../../../_out/extensions):/extensions:ro" \
			--privileged \
			"$(IMAGER_IMAGE)" --tar-to-stdout - | \
		tar -C ../../../_out/assets -xzf-
