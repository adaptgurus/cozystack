export NAME=vm-network
export NAMESPACE=cozy-system
include ../../../scripts/package.mk

update:
	rm -rf templates
	mkdir -p templates
	cat cozyrds/*.yaml > templates/cozyrd.yaml
