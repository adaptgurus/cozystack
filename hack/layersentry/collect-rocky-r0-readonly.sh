#!/usr/bin/env bash
set -uo pipefail

status() {
  local name=$1
  shift
  local value
  if value="$("$@" 2>/dev/null)"; then
    printf '%s=%s\n' "$name" "${value//$'\n'/,}"
  else
    printf '%s=NOT_AVAILABLE\n' "$name"
  fi
}

printf 'EVIDENCE_CLASS=R0_READ_ONLY_ROCKY_ACCEPTANCE\n'
printf 'CAPTURED_UTC=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
status HOSTNAME hostname -f
status OS_RELEASE rpm -E '%{rhel}'
status KERNEL uname -r
status SELINUX_MODE getenforce
status FIREWALLD_ACTIVE systemctl is-active firewalld
status FIREWALLD_ENABLED systemctl is-enabled firewalld
status CLOUDSTACK_MANAGEMENT_ACTIVE systemctl is-active cloudstack-management
status CLOUDSTACK_MANAGEMENT_ENABLED systemctl is-enabled cloudstack-management
status CLOUDSTACK_AGENT_ACTIVE systemctl is-active cloudstack-agent
status CLOUDSTACK_AGENT_ENABLED systemctl is-enabled cloudstack-agent
status MYSQLD_ACTIVE systemctl is-active mysqld
status MYSQLD_ENABLED systemctl is-enabled mysqld
status LIBVIRTD_ACTIVE systemctl is-active libvirtd
status LIBVIRTD_ENABLED systemctl is-enabled libvirtd

for package in cloudstack-management cloudstack-ui cloudstack-agent mysql-server java-17-openjdk qemu-kvm libvirt firewalld; do
  if version=$(rpm -q --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "$package" 2>/dev/null); then
    printf 'PACKAGE_%s=%s\n' "${package^^}" "$version"
  else
    printf 'PACKAGE_%s=NOT_INSTALLED\n' "${package^^}"
  fi
done

status FIREWALLD_ZONES firewall-cmd --get-active-zones
printf 'MUTATION_PERFORMED=false\n'
printf 'READ_ONLY_ROCKY_R0_INVENTORY_COMPLETE\n'
