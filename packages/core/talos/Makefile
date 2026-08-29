NAME=talos
NAMESPACE=cozy-system

TALOS_VERSION=$(shell awk '/^version:/ {print $$2}' images/talos/profiles/installer.yaml)
BASE_INSTALLER_IMAGE?=ghcr.io/siderolabs/installer:$(TALOS_VERSION)
IMAGER_IMAGE?=ghcr.io/siderolabs/imager:$(TALOS_VERSION)
LOCAL_REGISTRY?=127.0.0.1:5005
BUILD_TAG?=v1.13.6-layersentry-prod1
PKGS_PREFIX?=$(LOCAL_REGISTRY)/layersentry/pkgs

include ../../../hack/common-envs.mk

update:
	hack/gen-profiles.sh

layersentry-storage-server-extensions:
	mkdir -p ../../../_out/extensions
	sh hack/build-layersentry-iscsi-target-extension.sh ../../../_out/extensions
	sh hack/build-layersentry-nfs-server-extension.sh ../../../_out/extensions
	sh hack/build-layersentry-hci-tools-extension.sh ../../../_out/extensions
	for f in \
		layersentry-iscsi-target.tar layersentry-nfs-server.tar layersentry-hci-tools.tar \
		layersentry-iscsi-target.sbom.spdx.json layersentry-nfs-server.sbom.spdx.json \
		layersentry-hci-tools.sbom.spdx.json; do \
		test -s ../../../_out/extensions/$$f; \
	done

layersentry-kernel-extensions:
	mkdir -p ../../../_out/extensions
	LOCAL_REGISTRY="$(LOCAL_REGISTRY)" BUILD_TAG="$(BUILD_TAG)" PKGS_PREFIX="$(PKGS_PREFIX)" \
		bash hack/build-layersentry-kernel-extensions.sh ../../../_out/extensions
	test -s ../../../_out/extensions/layersentry-kernel-extensions.sha256

layersentry-production-extensions: layersentry-kernel-extensions layersentry-storage-server-extensions

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

assets: talos-iso talos-installer talos-nocloud talos-metal talos-kernel talos-initramfs

talos-iso:
	test -f ../../../_out/assets/metal-amd64.iso || $(MAKE) build-talos-iso

talos-installer:
	test -f ../../../_out/assets/metal-amd64-installer.tar || $(MAKE) build-talos-installer

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

layersentry-production-assets: layersentry-production-extensions
	rm -rf ../../../_out/assets
	mkdir -p ../../../_out/assets
	$(MAKE) build-talos-iso build-talos-installer \
		BASE_INSTALLER_IMAGE="$(BASE_INSTALLER_IMAGE)" IMAGER_IMAGE="$(IMAGER_IMAGE)"
	test -s ../../../_out/assets/metal-amd64.iso
	test -s ../../../_out/assets/metal-amd64-installer.tar
