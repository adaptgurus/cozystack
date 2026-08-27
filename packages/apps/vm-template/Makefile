include ../../../hack/package.mk

test:
	helm unittest .

generate:
	cozyvalues-gen -m 'vmtemplate' -v values.yaml -s values.schema.json -r README.md -g ../../../api/apps/v1alpha1/vmtemplate/types.go
	../../../hack/update-crd.sh
