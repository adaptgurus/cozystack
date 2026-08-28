// SPDX-License-Identifier: Apache-2.0

package virtualizationnaming

import (
	"strings"
	"testing"
)

func TestForVMWindows10(t *testing.T) {
	got, err := ForVM("windows10")
	if err != nil {
		t.Fatalf("ForVM returned error: %v", err)
	}
	if got.VM != "windows10" {
		t.Fatalf("VM = %q, want windows10", got.VM)
	}
	if got.OSDisk != "windows10osdisk" {
		t.Fatalf("OSDisk = %q, want windows10osdisk", got.OSDisk)
	}
	if got.DataDisk != "windows10datadisk" {
		t.Fatalf("DataDisk = %q, want windows10datadisk", got.DataDisk)
	}
	if got.NIC != "windows10nic" {
		t.Fatalf("NIC = %q, want windows10nic", got.NIC)
	}
	if got.Security != "windows10sec" {
		t.Fatalf("Security = %q, want windows10sec", got.Security)
	}
}

func TestIndexedChildren(t *testing.T) {
	if got, err := DataDisk("windows10", 2); err != nil || got != "windows10datadisk2" {
		t.Fatalf("DataDisk index 2 = %q, %v", got, err)
	}
	if got, err := NIC("windows10", 2); err != nil || got != "windows10nic2" {
		t.Fatalf("NIC index 2 = %q, %v", got, err)
	}
}

func TestCanonicalizesUserInput(t *testing.T) {
	got, err := ForVM(" Windows 10 PROD ")
	if err != nil {
		t.Fatalf("ForVM returned error: %v", err)
	}
	if got.VM != "windows-10-prod" {
		t.Fatalf("VM = %q, want windows-10-prod", got.VM)
	}
	if got.Security != "windows-10-prodsec" {
		t.Fatalf("Security = %q, want windows-10-prodsec", got.Security)
	}
}

func TestLongNamesStayDNSLabelSizedAndKeepRoleSuffix(t *testing.T) {
	base := strings.Repeat("a", 63)
	family, err := ForVM(base)
	if err != nil {
		t.Fatalf("ForVM returned error: %v", err)
	}
	for name, wantSuffix := range map[string]string{
		family.OSDisk:   "osdisk",
		family.DataDisk: "datadisk",
		family.NIC:      "nic",
		family.Security: "sec",
	} {
		if len(name) > 63 {
			t.Fatalf("generated name %q exceeds 63 characters", name)
		}
		if !strings.HasSuffix(name, wantSuffix) {
			t.Fatalf("generated name %q does not preserve suffix %q", name, wantSuffix)
		}
	}
}

func TestRejectsEmptyName(t *testing.T) {
	if _, err := ForVM(" --- "); err == nil {
		t.Fatal("expected empty normalized VM name to fail")
	}
}
