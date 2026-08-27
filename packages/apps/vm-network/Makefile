include ../../../hack/package.mk

test:
	helm unittest .

generate:
	cozyvalues-gen -m 'vmnetwork' -v values.yaml -s values.schema.json -r README.md -g ../../../api/apps/v1alpha1/vmnetwork/types.go
	../../../hack/update-crd.sh
