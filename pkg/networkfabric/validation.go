// SPDX-License-Identifier: Apache-2.0

package networkfabric

import (
	"fmt"
	"sort"
	"strings"

	k8svalidation "k8s.io/apimachinery/pkg/util/validation"
)

const linuxInterfaceNameMaxBytes = 15

func Validate(spec Spec) error {
	var errs []string
	if spec.Provider != ProviderTalos {
		errs = append(errs, fmt.Sprintf("provider must be %q", ProviderTalos))
	}
	if len(spec.ProtectedManagementInterfaces) == 0 {
		errs = append(errs, "at least one protectedManagementInterface is required")
	}
	if spec.Rollout.MaxUnavailable != 0 && spec.Rollout.MaxUnavailable != 1 {
		errs = append(errs, "rollout.maxUnavailable must be 1 (or 0 to use the safe default of 1)")
	}

	protected := map[string]struct{}{}
	for _, name := range spec.ProtectedManagementInterfaces {
		if name == "" {
			errs = append(errs, "protectedManagementInterfaces must not contain an empty name")
			continue
		}
		if problem := validateLinuxInterfaceName(name); problem != "" {
			errs = append(errs, fmt.Sprintf("protectedManagementInterface %q is invalid: %s", name, problem))
		}
		if _, duplicate := protected[name]; duplicate {
			errs = append(errs, fmt.Sprintf("duplicate protectedManagementInterface %q", name))
		}
		protected[name] = struct{}{}
	}

	names := map[string]struct{}{}
	bridges := map[string]struct{}{}
	vlanIfaces := map[string]struct{}{}
	migrationNetworks := 0
	for i, network := range spec.Networks {
		prefix := fmt.Sprintf("networks[%d]", i)
		if problems := k8svalidation.IsDNS1123Label(network.Name); len(problems) > 0 {
			errs = append(errs, fmt.Sprintf("%s.name %q is invalid: %s", prefix, network.Name, strings.Join(problems, "; ")))
		}
		if _, exists := names[network.Name]; exists {
			errs = append(errs, fmt.Sprintf("duplicate network name %q", network.Name))
		}
		names[network.Name] = struct{}{}

		if network.Uplink == "" {
			errs = append(errs, prefix+".uplink is required")
		} else {
			if problem := validateLinuxInterfaceName(network.Uplink); problem != "" {
				errs = append(errs, fmt.Sprintf("%s.uplink %q is invalid: %s", prefix, network.Uplink, problem))
			}
			if _, management := protected[network.Uplink]; management {
				errs = append(errs, fmt.Sprintf("%s.uplink %q is a protected management interface and cannot be used as a NetworkFabric uplink", prefix, network.Uplink))
			}
		}
		if network.Bridge == "" {
			errs = append(errs, prefix+".bridge is required")
		} else {
			if problem := validateLinuxInterfaceName(network.Bridge); problem != "" {
				errs = append(errs, fmt.Sprintf("%s.bridge %q is invalid: %s", prefix, network.Bridge, problem))
			}
			if _, exists := bridges[network.Bridge]; exists {
				errs = append(errs, fmt.Sprintf("duplicate bridge %q", network.Bridge))
			}
			bridges[network.Bridge] = struct{}{}
			if _, management := protected[network.Bridge]; management {
				errs = append(errs, fmt.Sprintf("%s.bridge %q cannot replace a protected management interface", prefix, network.Bridge))
			}
		}
		if network.Bridge != "" && network.Bridge == network.Uplink {
			errs = append(errs, prefix+".bridge must differ from uplink; node changes must be additive")
		}
		if network.VLAN < 0 || network.VLAN > 4094 {
			errs = append(errs, prefix+".vlan must be between 0 and 4094")
		}
		if network.MTU != 0 && (network.MTU < 576 || network.MTU > 9216) {
			errs = append(errs, prefix+".mtu must be 0 or between 576 and 9216")
		}
		if network.VLAN == 0 {
			if network.VLANInterface != "" {
				errs = append(errs, prefix+".vlanInterface must be empty for an untagged/native network")
			}
		}
		if network.VLAN > 0 {
			if network.VLANInterface == "" {
				errs = append(errs, prefix+".vlanInterface is required when vlan is non-zero")
			} else {
				if problem := validateLinuxInterfaceName(network.VLANInterface); problem != "" {
					errs = append(errs, fmt.Sprintf("%s.vlanInterface %q is invalid: %s", prefix, network.VLANInterface, problem))
				}
				expected := fmt.Sprintf("%s.%d", network.Uplink, network.VLAN)
				if network.VLANInterface != expected {
					errs = append(errs, fmt.Sprintf("%s.vlanInterface must be the deterministic derived name %q", prefix, expected))
				}
				if network.VLANInterface == network.Uplink || network.VLANInterface == network.Bridge {
					errs = append(errs, prefix+".vlanInterface must differ from uplink and bridge")
				}
				if _, management := protected[network.VLANInterface]; management {
					errs = append(errs, fmt.Sprintf("%s.vlanInterface %q cannot replace a protected management interface", prefix, network.VLANInterface))
				}
				if _, exists := vlanIfaces[network.VLANInterface]; exists {
					errs = append(errs, fmt.Sprintf("duplicate vlanInterface %q", network.VLANInterface))
				}
				vlanIfaces[network.VLANInterface] = struct{}{}
			}
		}
		if network.Migration {
			migrationNetworks++
		}
	}
	if migrationNetworks > 1 {
		errs = append(errs, "only one network may be marked as the live-migration network")
	}

	if len(errs) == 0 {
		return nil
	}
	sort.Strings(errs)
	return fmt.Errorf("invalid NetworkFabric: %s", strings.Join(errs, "; "))
}

func validateLinuxInterfaceName(name string) string {
	if name == "" {
		return "name must not be empty"
	}
	if len(name) > linuxInterfaceNameMaxBytes {
		return fmt.Sprintf("name exceeds Linux IFNAMSIZ limit of %d bytes", linuxInterfaceNameMaxBytes)
	}
	if name == "." || name == ".." {
		return "name must not be . or .."
	}
	if strings.ContainsAny(name, "/:\t\n\r ") {
		return "name contains characters prohibited by Linux interface naming rules"
	}
	return ""
}
