// SPDX-License-Identifier: Apache-2.0

package vmtemplate

import (
	"strings"
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

func TestValidateSourceAcceptsHaltedPersistentVMAndExcludesOptical(t *testing.T) {
	vm := testVM("Halted", []interface{}{
		map[string]interface{}{"name": "root", "dataVolume": map[string]interface{}{"name": "vm-disk-root"}},
		map[string]interface{}{"name": "installer", "dataVolume": map[string]interface{}{"name": "vm-disk-installer"}},
		map[string]interface{}{"name": "cloudinit", "cloudInitNoCloud": map[string]interface{}{"secretRef": map[string]interface{}{"name": "vm-cloudinit"}}},
	}, []interface{}{
		map[string]interface{}{"name": "root", "disk": map[string]interface{}{}},
		map[string]interface{}{"name": "installer", "cdrom": map[string]interface{}{"bus": "sata"}},
	})

	summary, err := ValidateSource(vm, false, SourcePolicy{RequireHalted: true, ExcludeOpticalMedia: true, AllowSecretReferences: true})
	if err != nil {
		t.Fatalf("ValidateSource: %v", err)
	}
	if got := strings.Join(summary.PersistentVolumes, ","); got != "root" {
		t.Fatalf("persistent volumes = %q, want root", got)
	}
	if got := strings.Join(summary.OpticalVolumes, ","); got != "installer" {
		t.Fatalf("optical volumes = %q, want installer", got)
	}
	if got := strings.Join(summary.SecretReferenceVolumes, ","); got != "cloudinit" {
		t.Fatalf("secret reference volumes = %q, want cloudinit", got)
	}
}

func TestValidateSourceRejectsActiveOrRestartableVM(t *testing.T) {
	vm := testVM("Halted", []interface{}{
		map[string]interface{}{"name": "root", "dataVolume": map[string]interface{}{"name": "vm-disk-root"}},
	}, nil)
	if _, err := ValidateSource(vm, true, SourcePolicy{RequireHalted: true}); err == nil || !strings.Contains(err.Error(), "active VMI") {
		t.Fatalf("expected active VMI rejection, got %v", err)
	}

	vm.Object["spec"].(map[string]interface{})["runStrategy"] = "Always"
	if _, err := ValidateSource(vm, false, SourcePolicy{RequireHalted: true}); err == nil || !strings.Contains(err.Error(), "runStrategy=Halted") {
		t.Fatalf("expected restartable VM rejection, got %v", err)
	}
}

func TestValidateSourceRejectsUnsafeLocalAndDuplicateWritableStorage(t *testing.T) {
	vm := testVM("Halted", []interface{}{
		map[string]interface{}{"name": "root", "hostDisk": map[string]interface{}{"path": "/var/lib/vm/root.img"}},
	}, nil)
	if _, err := ValidateSource(vm, false, SourcePolicy{RequireHalted: true}); err == nil || !strings.Contains(err.Error(), "hostDisk") {
		t.Fatalf("expected hostDisk rejection, got %v", err)
	}

	vm = testVM("Halted", []interface{}{
		map[string]interface{}{"name": "root-a", "persistentVolumeClaim": map[string]interface{}{"claimName": "same-pvc"}},
		map[string]interface{}{"name": "root-b", "persistentVolumeClaim": map[string]interface{}{"claimName": "same-pvc"}},
	}, nil)
	if _, err := ValidateSource(vm, false, SourcePolicy{RequireHalted: true}); err == nil || !strings.Contains(err.Error(), "same writable storage") {
		t.Fatalf("expected duplicate writable storage rejection, got %v", err)
	}
}

func TestValidateSourceRejectsSecretReferencesForGlobalPromotion(t *testing.T) {
	vm := testVM("Halted", []interface{}{
		map[string]interface{}{"name": "root", "dataVolume": map[string]interface{}{"name": "vm-disk-root"}},
		map[string]interface{}{"name": "sysprep", "sysprep": map[string]interface{}{"secret": map[string]interface{}{"name": "unattend"}}},
	}, nil)
	if _, err := ValidateSource(vm, false, SourcePolicy{RequireHalted: true, AllowSecretReferences: false}); err == nil || !strings.Contains(err.Error(), "global template promotion") {
		t.Fatalf("expected secret promotion rejection, got %v", err)
	}
}

func TestValidateSourceRequiresPersistentDiskAfterOpticalExclusion(t *testing.T) {
	vm := testVM("Halted", []interface{}{
		map[string]interface{}{"name": "installer", "dataVolume": map[string]interface{}{"name": "vm-disk-installer"}},
	}, []interface{}{
		map[string]interface{}{"name": "installer", "cdrom": map[string]interface{}{"bus": "sata"}},
	})
	if _, err := ValidateSource(vm, false, SourcePolicy{RequireHalted: true, ExcludeOpticalMedia: true}); err == nil || !strings.Contains(err.Error(), "no snapshot/clone-capable persistent disk") {
		t.Fatalf("expected persistent disk rejection, got %v", err)
	}
}

func testVM(runStrategy string, volumes, disks []interface{}) *unstructured.Unstructured {
	if disks == nil {
		disks = []interface{}{}
	}
	return &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "kubevirt.io/v1",
		"kind":       "VirtualMachine",
		"metadata": map[string]interface{}{
			"name":      "vm-instance-source",
			"namespace": "tenant-test",
		},
		"spec": map[string]interface{}{
			"runStrategy": runStrategy,
			"template": map[string]interface{}{
				"spec": map[string]interface{}{
					"domain": map[string]interface{}{
						"devices": map[string]interface{}{"disks": disks},
					},
					"volumes": volumes,
				},
			},
		},
	}}
}
