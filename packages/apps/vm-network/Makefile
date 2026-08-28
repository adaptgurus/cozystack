include ../../../hack/package.mk

test:
	helm unittest .

generate:
	cozyvalues-gen -m 'vmnetwork' -v values.yaml -s values.schema.json -r README.md -g ../../../api/apps/v1alpha1/vmnetwork/types.go
	@tmp=$$(mktemp); jq '."x-kubernetes-validations" = [{"rule":"(self.fabricRef == \"\" && self.fabricNetwork == \"\") || (self.fabricRef != \"\" && self.fabricNetwork != \"\")","message":"fabricRef and fabricNetwork must be set together"}] | .properties.mtu."x-kubernetes-validations" = [{"rule":"self == 0 || self >= 576","message":"mtu must be 0 or between 576 and 9216"}]' values.schema.json > $$tmp && mv $$tmp values.schema.json
	../../../hack/update-crd.sh
