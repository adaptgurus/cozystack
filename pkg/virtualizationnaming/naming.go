// SPDX-License-Identifier: Apache-2.0

// Package virtualizationnaming defines the canonical user-facing resource
// family used by HCI virtualization workflows. Kubernetes namespaces remain
// tenant workload namespaces; these names identify the VM and its associated
// resources inside that namespace.
package virtualizationnaming

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"regexp"
	"strings"
)

const maxDNSLabelLength = 63

var invalidDNSLabelChars = regexp.MustCompile(`[^a-z0-9-]+`)

// Family contains the canonical first resources associated with a VM.
type Family struct {
	VM       string
	OSDisk   string
	DataDisk string
	NIC      string
	Security string
}

// ForVM returns the canonical resource family for vmName.
//
// Example for "windows10":
//   VM       = windows10
//   OSDisk   = windows10osdisk
//   DataDisk = windows10datadisk
//   NIC      = windows10nic
//   Security = windows10sec
func ForVM(vmName string) (Family, error) {
	base, err := CanonicalVMName(vmName)
	if err != nil {
		return Family{}, err
	}
	return Family{
		VM:       base,
		OSDisk:   child(base, "osdisk"),
		DataDisk: child(base, "datadisk"),
		NIC:      child(base, "nic"),
		Security: child(base, "sec"),
	}, nil
}

// CanonicalVMName validates and normalizes a VM name to a DNS-label-safe
// user-facing name. It intentionally does not add implementation prefixes such
// as vm-instance- or vm-disk-.
func CanonicalVMName(name string) (string, error) {
	name = strings.ToLower(strings.TrimSpace(name))
	name = invalidDNSLabelChars.ReplaceAllString(name, "-")
	name = strings.Trim(name, "-")
	for strings.Contains(name, "--") {
		name = strings.ReplaceAll(name, "--", "-")
	}
	if name == "" {
		return "", fmt.Errorf("VM name is empty after DNS-label normalization")
	}
	if len(name) > maxDNSLabelLength {
		name = stableShorten(name, "")
	}
	return name, nil
}

// DataDisk returns <vm>datadisk for index 1 and <vm>datadiskN for later disks.
func DataDisk(vm string, index int) (string, error) {
	base, err := CanonicalVMName(vm)
	if err != nil {
		return "", err
	}
	if index < 1 {
		return "", fmt.Errorf("data disk index must be >= 1")
	}
	suffix := "datadisk"
	if index > 1 {
		suffix = fmt.Sprintf("datadisk%d", index)
	}
	return child(base, suffix), nil
}

// NIC returns <vm>nic for index 1 and <vm>nicN for later NICs.
func NIC(vm string, index int) (string, error) {
	base, err := CanonicalVMName(vm)
	if err != nil {
		return "", err
	}
	if index < 1 {
		return "", fmt.Errorf("NIC index must be >= 1")
	}
	suffix := "nic"
	if index > 1 {
		suffix = fmt.Sprintf("nic%d", index)
	}
	return child(base, suffix), nil
}

func child(base, suffix string) string {
	candidate := base + suffix
	if len(candidate) <= maxDNSLabelLength {
		return candidate
	}
	return stableShorten(base, suffix)
}

func stableShorten(base, suffix string) string {
	sum := sha256.Sum256([]byte(base))
	hash := hex.EncodeToString(sum[:])[:8]
	// One '-' separates the shortened base from its collision-resistant hash.
	room := maxDNSLabelLength - len(suffix) - len(hash) - 1
	if room < 1 {
		room = 1
	}
	short := strings.TrimRight(base[:min(room, len(base))], "-")
	if short == "" {
		short = "v"
	}
	return short + "-" + hash + suffix
}
