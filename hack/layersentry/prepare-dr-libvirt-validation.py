#!/usr/bin/env python3
"""Exact disposable DR host prerequisites; no guest, disk or network changes."""
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

TARGET = "10.10.10.20"
PACKAGES = ("libvirt-daemon-kvm", "libvirt-client", "python3-libvirt", "qemu-kvm", "qemu-img")
SOCKETS = ("virtlogd.socket", "virtlockd.socket", "virtqemud.socket")


class Refused(Exception):
    pass


def require(value, code):
    if not value:
        raise Refused(code)


def command(argv, timeout=20, allowed=(0,)):
    result = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, timeout=timeout, text=True)
    require(result.returncode in allowed, "COMMAND_FAILED")
    require(len(result.stdout) <= 4 * 1024 * 1024, "OUTPUT_LIMIT")
    return result.stdout.strip()


def baseline():
    require(os.geteuid() == 0, "ROOT_REQUIRED")
    addresses = json.loads(command(["ip", "-j", "-4", "address", "show"]))
    require(TARGET in [a.get("local") for link in addresses for a in link.get("addr_info", [])], "TARGET_MISMATCH")
    require(command(["hostname", "-f"]) == "layersentry-dr-mgmt1", "HOSTNAME_MISMATCH")
    release = command(["rpm", "-q", "--qf", "%{VERSION}", "rocky-release"])
    require(re.fullmatch(r"9\.[0-9]+", release), "ROCKY9_REQUIRED")
    require(command(["systemctl", "is-active", "cloudstack-management"]) == "active", "MANAGEMENT_NOT_ACTIVE")
    require(command(["systemctl", "show", "--property=ActiveState", "--value", "cloudstack-agent"]) == "inactive", "AGENT_OWNERSHIP_CONFLICT")
    security = {"selinux": command(["getenforce"]),
                "firewalld": command(["systemctl", "show", "--property=ActiveState", "--value", "firewalld"])}
    require(security["selinux"] == "Enforcing", "SELINUX_ENFORCING_REQUIRED")
    require(security["firewalld"] == "active", "FIREWALL_ACTIVE_REQUIRED")
    require(Path("/dev/kvm").exists() and stat.S_ISCHR(Path("/dev/kvm").stat().st_mode), "KVM_DEVICE_REQUIRED")
    require(command(["systemctl", "show", "--property=ActiveState", "--value", "libvirtd"]) == "inactive", "MONOLITHIC_LIBVIRT_CONFLICT")
    require(not list(Path("/etc/libvirt/qemu").glob("*.xml")), "EXISTING_DOMAIN_CONFIGURATION")
    # Exact network state is compared after packages/socket startup, never edited.
    return {"rocky": release, "security": security, "addresses": addresses,
            "links": json.loads(command(["ip", "-j", "link", "show"]))}


def journal_directory():
    current = os.open("/var/lib", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for name in ("layersentry-validation", "dr-libvirt"):
            try:
                os.mkdir(name, 0o700, dir_fd=current)
            except FileExistsError:
                pass
            child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=current)
            info = os.fstat(child)
            require(info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o700, "JOURNAL_OWNER_MODE")
            os.close(current)
            current = child
        return current
    except BaseException:
        os.close(current)
        raise


def write_state(folder, name, state):
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=folder)
    try:
        with os.fdopen(fd, "w", closefd=False) as stream:
            json.dump(state, stream, sort_keys=True)
            stream.flush()
        os.fsync(fd)
        os.fsync(folder)
    finally:
        os.close(fd)


def prepare(run_id):
    require(re.fullmatch(r"[0-9]{1,20}", run_id), "INVALID_RUN_ID")
    state = {"schemaVersion": "1.0", "target": TARGET, "runId": run_id,
             "status": "PENDING", "mutationAttempted": False,
             "guestCreated": False, "diskFormatted": False, "networkChanged": False}
    folder = None
    try:
        before = baseline()
        state.update(rocky=before["rocky"], security=before["security"])
        folder = journal_directory()
        fcntl.flock(folder, fcntl.LOCK_EX | fcntl.LOCK_NB)
        require(not any(name.endswith("-started.json") and not name.replace("-started", "-finished") in os.listdir(folder)
                        for name in os.listdir(folder)), "PREVIOUS_ATTEMPT_REQUIRES_INSPECTION")
        write_state(folder, run_id + "-started.json", state)
        state["stage"] = "SIGNED_ROCKY_PACKAGES"
        state["mutationAttempted"] = True
        command(["dnf", "-y", "--disablerepo=*", "--enablerepo=baseos,appstream,crb",
                 "--setopt=gpgcheck=1", "--setopt=*.gpgcheck=1", "--setopt=localpkg_gpgcheck=1",
                 "--setopt=sslverify=1", "--setopt=*.sslverify=1",
                 "--setopt=install_weak_deps=False", "--setopt=timeout=30", "--setopt=retries=1",
                 "install", *PACKAGES], timeout=900)
        state["stage"] = "LOCAL_LIBVIRT_SOCKETS"
        command(["systemctl", "start", *SOCKETS], timeout=60)
        require(not command(["virsh", "--readonly", "-c", "qemu:///system", "list", "--all", "--uuid"]), "EXISTING_DOMAIN_CONFLICT")
        versions = command(["rpm", "-q", "--qf", "%{NAME} %{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}\n", *PACKAGES]).splitlines()
        require(len(versions) == len(PACKAGES) and all(re.fullmatch(r"[A-Za-z0-9_.:+ -]+", line) for line in versions), "VERSION_OUTPUT_INVALID")
        state["packages"] = versions
        code = "import json,libvirt; c=libvirt.openReadOnly('qemu:///system'); print(json.dumps({'libvirt':c.getLibVersion(),'qemu':c.getVersion(),'domains':c.numOfDomains()})); c.close()"
        state["provider"] = json.loads(command(["python3", "-c", code]))
        after = baseline()
        require(before == after, "HOST_BASELINE_CHANGED")
        state["securityPreserved"] = True
        state["status"] = "PREREQUISITES_VERIFIED"
        write_state(folder, run_id + "-finished.json", state)
    except BaseException as error:
        state["status"] = "FAILED_REQUIRES_INSPECTION" if state["mutationAttempted"] else "REFUSED_BEFORE_PACKAGES"
        state["reason"] = str(error) if isinstance(error, Refused) else type(error).__name__
        # An unfinished journal prohibits automatic replay after mutation uncertainty.
    finally:
        if folder is not None:
            os.close(folder)
    return state


def reconcile_socket(run_id, prior_run, *, iso_only=False):
    require(re.fullmatch(r"[0-9]{1,20}", run_id) and re.fullmatch(r"[0-9]{1,20}", prior_run) and run_id != prior_run, "INVALID_RUN_BINDING")
    state = {"schemaVersion": "1.0", "runId": run_id, "priorRunId": prior_run, "target": TARGET,
             "status": "PENDING", "mutationAttempted": False, "guestCreated": False, "diskFormatted": False, "networkChanged": False}
    folder = None
    try:
        before = baseline()
        state["security"] = before["security"]
        folder = journal_directory()
        fcntl.flock(folder, fcntl.LOCK_EX | fcntl.LOCK_NB)
        names = set(os.listdir(folder))
        unfinished = {name for name in names if name.endswith("-started.json") and name.replace("-started", "-finished") not in names}
        require(prior_run + "-started.json" in unfinished, "EXACT_UNFINISHED_ATTEMPT_REQUIRED")
        fd = os.open(prior_run + "-started.json", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=folder)
        try:
            info = os.fstat(fd)
            require(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and info.st_nlink == 1 and info.st_size < 8192, "UNSAFE_PRIOR_JOURNAL")
            prior = json.loads(os.read(fd, 8192))
        finally:
            os.close(fd)
        require(prior.get("target") == TARGET and prior.get("runId") == prior_run, "PRIOR_SCOPE_MISMATCH")
        ancestor = prior.get("priorRunId") if iso_only else None
        if iso_only:
            require(isinstance(ancestor, str) and re.fullmatch(r"[0-9]{1,20}", ancestor), "PRIOR_RECONCILIATION_REQUIRED")
        expected = {prior_run + "-started.json"} | ({ancestor + "-started.json"} if ancestor else set())
        require(unfinished == expected, "EXACT_UNFINISHED_ATTEMPT_REQUIRED")
        # The observed failure is the missing read-only endpoint. Refuse any
        # broader repair: all previously started local sockets must be active.
        for name in SOCKETS:
            require(command(["systemctl", "is-active", name]) == "active", "ORIGINAL_SOCKET_STATE_CHANGED")
        require(command(["systemctl", "show", "--property=LoadState", "--value", "virtqemud-ro.socket"]) == "loaded", "READONLY_SOCKET_UNIT_MISSING")
        require(command(["systemctl", "show", "--property=ActiveState", "--value", "virtqemud-ro.socket"]) == ("active" if iso_only else "inactive"), "READONLY_SOCKET_NOT_CAUSAL")
        require(Path("/run/libvirt/virtqemud-sock-ro").exists() == iso_only, "READONLY_LISTENER_STATE_CHANGED")
        state["packages"] = command(["rpm", "-q", "--qf", "%{NAME} %{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}\n", *PACKAGES]).splitlines()
        write_state(folder, run_id + "-started.json", state)
        state.update(mutationAttempted=True, stage="READONLY_SOCKET_START")
        if not iso_only:
            command(["systemctl", "start", "virtqemud-ro.socket"], timeout=60)
        require(not command(["virsh", "--readonly", "-c", "qemu:///system", "list", "--all", "--uuid"]), "EXISTING_DOMAIN_CONFLICT")
        state["provider"] = json.loads(command(["python3", "-c", "import json,libvirt; c=libvirt.openReadOnly('qemu:///system'); print(json.dumps({'libvirt':c.getLibVersion(),'qemu':c.getVersion(),'domains':c.numOfDomains()})); c.close() "]))
        state["stage"] = "SIGNED_NOCLOUD_ISO_TOOL"
        command(["dnf", "-y", "--disablerepo=*", "--enablerepo=baseos,appstream,crb",
                 "--setopt=*.gpgcheck=1", "--setopt=localpkg_gpgcheck=1", "--setopt=*.sslverify=1",
                 "--setopt=install_weak_deps=False", "--setopt=timeout=30", "--setopt=retries=1",
                 "install", "xorriso"], timeout=600)
        state["isoTool"] = command(["rpm", "-q", "--qf", "%{NAME} %{VERSION}-%{RELEASE}.%{ARCH}", "xorriso"])
        require(baseline() == before, "HOST_BASELINE_CHANGED")
        state.update(status="PREREQUISITES_VERIFIED", securityPreserved=True)
        write_state(folder, run_id + "-finished.json", state)
        write_state(folder, prior_run + "-finished.json", {"status": "PREREQUISITES_VERIFIED", "reconciledByRun": run_id, "target": TARGET})
        if ancestor:
            write_state(folder, ancestor + "-finished.json", {"status": "PREREQUISITES_VERIFIED", "reconciledByRun": run_id, "target": TARGET})
    except BaseException as error:
        state["status"] = "FAILED_REQUIRES_INSPECTION" if state["mutationAttempted"] else "REFUSED_BEFORE_MUTATION"
        state["reason"] = str(error) if isinstance(error, Refused) else type(error).__name__
    finally:
        if folder is not None:
            os.close(folder)
    return state


def inspect(run_id):
    require(re.fullmatch(r"[0-9]{1,20}", run_id), "INVALID_RUN_ID")
    before = baseline()
    result = {"schemaVersion": "1.0", "runId": run_id, "target": TARGET,
              "status": "INSPECTED", "mutationAttempted": False,
              "security": before["security"], "units": {}, "packages": {},
              "rootFilesystemFreeBytes": os.statvfs("/var/lib/libvirt/images").f_bavail * os.statvfs("/var/lib/libvirt/images").f_frsize}
    for name in (*SOCKETS, "virtqemud-ro.socket", "virtqemud.service", "virtlogd.service", "virtlockd.service"):
        value = command(["systemctl", "show", "--property=LoadState,ActiveState,Result,FragmentPath", name])
        result["units"][name] = value.splitlines()
    for name in (*PACKAGES, "libvirt-daemon-log", "libvirt-daemon-lock", "libvirt-daemon-driver-qemu"):
        value = command(["rpm", "-q", "--qf", "%{NAME} %{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}", name], allowed=(0, 1))
        require(re.fullmatch(r"[A-Za-z0-9_.:+ /-]{1,256}", value), "INVALID_PACKAGE_OUTPUT")
        result["packages"][name] = value
    for name, argv in {"domains": ["virsh", "--readonly", "-c", "qemu:///system", "list", "--all", "--uuid"],
                       "versions": ["virsh", "--readonly", "-c", "qemu:///system", "version"]}.items():
        try:
            result[name] = {"status": "OK", "output": command(argv).splitlines()}
        except Refused as error:
            result[name] = {"status": str(error)}
    return result


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4) or sys.argv[2] not in {"prepare", "inspect", "reconcile-socket", "complete-iso-tool"}:
        raise SystemExit("RUN_ID_REQUIRED")
    if sys.argv[2] in {"reconcile-socket", "complete-iso-tool"}:
        require(len(sys.argv) == 4, "PRIOR_RUN_REQUIRED")
        result = reconcile_socket(sys.argv[1], sys.argv[3], iso_only=sys.argv[2] == "complete-iso-tool")
    else:
        result = inspect(sys.argv[1]) if sys.argv[2] == "inspect" else prepare(sys.argv[1])
    print(json.dumps(result, sort_keys=True))
    raise SystemExit(0 if result["status"] in {"PREREQUISITES_VERIFIED", "INSPECTED"} else 1)
