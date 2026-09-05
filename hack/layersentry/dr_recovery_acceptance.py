#!/usr/bin/env python3
"""Bounded native CloudStack recovery acceptance; never certifies guest data."""

import argparse
import base64
import datetime
import fcntl
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import tempfile
import urllib.parse
import urllib.request
import uuid


class GateError(Exception):
    """Only fixed, non-sensitive diagnostic codes reach stdout."""


def require(ok, code):
    if not ok:
        raise GateError(code)


def identifier(value):
    require(isinstance(value, str), "INVALID_UUID")
    try:
        require(str(uuid.UUID(value)) == value, "INVALID_UUID")
    except ValueError:
        raise GateError("INVALID_UUID") from None
    return value


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def fixture_check(f):
    require(set(f) == {"run_id", "source_vm_id", "source_zone_id", "destination_zone_id",
                       "account_id", "account", "domain_id", "repository_id", "offering_id",
                       "template_id", "service_offering_id", "network_map", "points"}, "FIXTURE_FIELDS")
    for key in f:
        if key.endswith("_id"):
            identifier(f[key])
    require(isinstance(f["account"], str) and re.fullmatch(r"[A-Za-z0-9_.-]{1,64}", f["account"]), "INVALID_ACCOUNT")
    require(f["source_zone_id"] != f["destination_zone_id"], "SAME_ZONE")
    mappings = f["network_map"]
    require(isinstance(mappings, list) and 1 <= len(mappings) <= 16, "MISSING_NETWORK_MAPPING")
    for mapping in mappings:
        require(set(mapping) == {"source", "destination"}, "NETWORK_MAPPING_FIELDS")
        identifier(mapping["source"])
        identifier(mapping["destination"])
    for key in ("source", "destination"):
        require(len({m[key] for m in mappings}) == len(mappings), "DUPLICATE_NETWORK_MAPPING")
    require(set(f["points"]) == {"latest", "older"}, "CHECKPOINT_FIELDS")
    for point in f["points"].values():
        require(set(point) == {"backup_id", "disk_hashes"}, "CHECKPOINT_FIELDS")
        identifier(point["backup_id"])
        hashes = point["disk_hashes"]
        require(isinstance(hashes, dict) and 1 <= len(hashes) <= 16 and "0" in hashes, "DISK_HASHES_REQUIRED")
        for device, sha in hashes.items():
            require(re.fullmatch(r"0|[1-9][0-9]?", device) and isinstance(sha, str)
                    and re.fullmatch(r"[0-9a-f]{64}", sha), "INVALID_DISK_HASH")
    latest, older = f["points"]["latest"], f["points"]["older"]
    require(latest["backup_id"] != older["backup_id"], "DISTINCT_BACKUPS_REQUIRED")
    require(set(latest["disk_hashes"]) == set(older["disk_hashes"]), "CHECKPOINT_DISKS_DIFFER")
    require(all(latest["disk_hashes"][d] != older["disk_hashes"][d] for d in latest["disk_hashes"]), "DISTINCT_MARKERS_REQUIRED")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise GateError("API_REDIRECT_REFUSED")


class Client:
    def __init__(self, endpoint, key, secret):
        parsed = urllib.parse.urlsplit(endpoint)
        require(parsed.scheme == "https" or (parsed.scheme == "http" and parsed.hostname in {"127.0.0.1", "::1"}), "TLS_REQUIRED")
        require(parsed.hostname and not parsed.username and not parsed.password and not parsed.query
                and not parsed.fragment and parsed.path == "/client/api", "INVALID_ENDPOINT")
        require(key and secret, "API_CREDENTIALS_REQUIRED")
        self.endpoint, self.key, self.secret = endpoint, key, secret
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def __call__(self, command, **params):
        values = {"command": command, "response": "json", "apikey": self.key, **params}
        encoded = urllib.parse.urlencode(sorted((k, str(v)) for k, v in values.items()), quote_via=urllib.parse.quote)
        signature = base64.b64encode(hmac.new(self.secret.encode(), encoded.lower().encode(), hashlib.sha1).digest()).decode()
        body = (encoded + "&signature=" + urllib.parse.quote(signature, safe="")).encode()
        request = urllib.request.Request(self.endpoint, data=body, method="POST")
        try:
            with self.opener.open(request, timeout=30) as response:
                raw = response.read(2 * 1024 * 1024 + 1)
            require(len(raw) <= 2 * 1024 * 1024, "API_RESPONSE_TOO_LARGE")
            payload = json.loads(raw)
            result = payload.get(command.lower() + "response")
            require(isinstance(result, dict) and "errorcode" not in result, "API_REJECTED")
            return result
        except GateError:
            raise
        except Exception:
            raise GateError("API_TRANSPORT_OR_RESPONSE_FAILURE") from None


def one(api, command, kind, resource_id, **params):
    rows = api(command, id=resource_id, **params).get(kind, [])
    require(isinstance(rows, list) and len(rows) == 1 and rows[0].get("id") == resource_id, "RESOURCE_MISSING_OR_UNAUTHORIZED")
    return rows[0]


def owner_check(resource, f):
    require(resource.get("account") == f["account"] and resource.get("domainid") == f["domain_id"], "OWNER_MISMATCH")
    if "accountid" in resource:
        require(resource["accountid"] == f["account_id"], "OWNER_MISMATCH")
    require(not resource.get("projectid"), "PROJECT_FIXTURE_UNSUPPORTED")


def preflight(api, f):
    fixture_check(f)
    account = one(api, "listAccounts", "account", f["account_id"])
    require(account.get("name") == f["account"] and account.get("domainid") == f["domain_id"]
            and account.get("state") == "enabled", "ACCOUNT_NOT_ENABLED_OR_MISMATCH")
    for zone_id in (f["source_zone_id"], f["destination_zone_id"]):
        zone = one(api, "listZones", "zone", zone_id)
        require(zone.get("allocationstate") == "Enabled", "ZONE_NOT_ENABLED")
        if zone_id == f["destination_zone_id"]:
            require(zone.get("networktype") == "Advanced", "BASIC_DESTINATION_NATIVE_BACKUP_NETWORK_IDS_UNSUPPORTED")
    vm = one(api, "listVirtualMachines", "virtualmachine", f["source_vm_id"])
    owner_check(vm, f)
    require(vm.get("zoneid") == f["source_zone_id"] and vm.get("hypervisor") == "KVM"
            and vm.get("state") == "Stopped", "SOURCE_VM_NOT_STOPPED_KVM_IN_SOURCE_ZONE")
    source_networks = {nic.get("networkid") for nic in vm.get("nic", [])}
    require(source_networks == {m["source"] for m in f["network_map"]}, "INCOMPLETE_NIC_MAPPING")
    for mapping in f["network_map"]:
        network = one(api, "listNetworks", "network", mapping["destination"])
        owner_check(network, f)
        require(network.get("zoneid") == f["destination_zone_id"] and network.get("state") in {"Allocated", "Implemented"}, "DESTINATION_NETWORK_INVALID")
    repository = one(api, "listBackupRepositories", "backuprepository", f["repository_id"])
    require(repository.get("zoneid") == f["source_zone_id"] and repository.get("provider") == "nas"
            and repository.get("crosszoneinstancecreation") is True, "REPOSITORY_NOT_CROSS_ZONE_NAS")
    offering = one(api, "listBackupOfferings", "backupoffering", f["offering_id"])
    require(offering.get("externalid") == f["repository_id"] and offering.get("provider") == "nas"
            and offering.get("zoneid") == f["source_zone_id"], "OFFERING_REPOSITORY_MISMATCH")
    template = one(api, "listTemplates", "template", f["template_id"], templatefilter="executable", zoneid=f["destination_zone_id"])
    require(template.get("isready") is True and template.get("hypervisor") == "KVM", "TEMPLATE_NOT_READY_KVM")
    one(api, "listServiceOfferings", "serviceoffering", f["service_offering_id"])
    dates = {}
    for label, point in f["points"].items():
        backup = one(api, "listBackups", "backup", point["backup_id"])
        owner_check(backup, f)
        require(backup.get("virtualmachineid") == f["source_vm_id"] and backup.get("zoneid") == f["source_zone_id"]
                and backup.get("backupofferingid") == f["offering_id"] and backup.get("status") == "BackedUp", "BACKUP_FIXTURE_MISMATCH")
        volumes = backup.get("volumes")
        if isinstance(volumes, str):
            volumes = json.loads(volumes)
        require(isinstance(volumes, list) and {str(v.get("deviceId")) for v in volumes} == set(point["disk_hashes"]), "BACKUP_DISK_MAPPING_MISMATCH")
        dates[label] = datetime.datetime.strptime(backup["created"], "%Y-%m-%dT%H:%M:%S%z")
    require(dates["latest"] > dates["older"], "CHECKPOINT_ORDER_MISMATCH")
    return {"api_preflight": "PASS", "repository_mount": "NOT_TESTED", "guest_data": "NOT_TESTED", "e2e": "NOT_TESTED"}


class Journal:
    """Single runner, crash durable journal. Keep outside the repository/artifact input."""
    def __init__(self, directory, f, endpoint):
        self.directory = Path(directory)
        require(self.directory.is_dir() and not self.directory.is_symlink(), "PRIVATE_JOURNAL_DIRECTORY_REQUIRED")
        require(self.directory.stat().st_uid == os.getuid() and self.directory.stat().st_mode & 0o077 == 0, "PRIVATE_JOURNAL_DIRECTORY_REQUIRED")
        self.lock = os.open(self.directory / "lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(self.lock)
            raise GateError("JOURNAL_BUSY") from None
        try:
            self.path = self.directory / "journal.json"
            require(not self.path.is_symlink(), "JOURNAL_SYMLINK")
            binding = digest({"fixture": f, "endpoint": endpoint})
            if self.path.exists():
                require(self.path.stat().st_size <= 65536, "JOURNAL_TOO_LARGE")
                self.data = json.loads(self.path.read_text())
                require(self.data.get("binding") == binding, "JOURNAL_BINDING_MISMATCH")
            else:
                self.data = {"binding": binding, "operations": {}}
                self.save()
        except Exception:
            os.close(self.lock)
            raise

    def save(self):
        fd, name = tempfile.mkstemp(dir=self.directory, prefix="journal-")
        with os.fdopen(fd, "w") as handle:
            json.dump(self.data, handle, sort_keys=True)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(name, self.path)
        directory_fd = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)

    def close(self):
        os.close(self.lock)


def vm_check(api, vm_id, name, f):
    identifier(vm_id)
    require(vm_id != f["source_vm_id"], "SOURCE_VM_PROTECTED")
    vm = one(api, "listVirtualMachines", "virtualmachine", vm_id)
    owner_check(vm, f)
    require(vm.get("name") == name and vm.get("zoneid") == f["destination_zone_id"]
            and vm.get("state") == "Stopped", "RECOVERY_VM_SCOPE_OR_STATE_MISMATCH")
    require({n.get("networkid") for n in vm.get("nic", [])} == {m["destination"] for m in f["network_map"]}, "RECOVERY_NETWORK_MISMATCH")
    return vm


def reconcile(api, operation, journal):
    require(operation.get("job_id"), "SUBMISSION_UNCERTAIN_MANUAL_JOB_RECOVERY_REQUIRED")
    result = api("queryAsyncJobResult", jobid=operation["job_id"])
    status = result.get("jobstatus")
    require(status in {0, 1, 2}, "INVALID_JOB_STATUS")
    if status == 0:
        return "PENDING"
    if status == 2:
        operation["state"] = "FAILED"
        journal.save()
        raise GateError("ASYNC_JOB_FAILED_INSPECT_RECORDED_JOB")
    if operation["command"] == "createVMFromBackup":
        vm_id = result.get("jobresult", {}).get("virtualmachine", {}).get("id")
        operation["vm_id"] = identifier(vm_id)
    operation["state"] = "COMPLETE"
    journal.save()
    return "COMPLETE"


def submit_once(api, journal, key, command, params, execute):
    operations = journal.data["operations"]
    if key not in operations:
        require(execute, "NOT_SUBMITTED")
        operations[key] = {"command": command, "params": params, "state": "SUBMITTING"}
        journal.save()  # Persist intent before any bytes can reach CloudStack.
        result = api(command, **params)
        operations[key]["job_id"] = identifier(result.get("jobid"))
        operations[key]["state"] = "SUBMITTED"
        journal.save()
    operation = operations[key]
    require(operation["command"] == command and operation["params"] == params, "JOURNAL_OPERATION_MISMATCH")
    require(operation["state"] != "FAILED", "ASYNC_JOB_FAILED_INSPECT_RECORDED_JOB")
    if operation["state"] != "COMPLETE":
        reconcile(api, operation, journal)
    return operation


def recover(api, f, journal, execute=False):
    preflight(api, f)
    evidence = {"guest_data": "NOT_TESTED", "e2e": "NOT_TESTED", "points": {}}
    for label in ("older", "latest"):
        if not execute and label not in journal.data["operations"]:
            evidence["points"][label] = {"state": "NOT_SUBMITTED"}
            break
        name = "dr-" + f["run_id"] + "-" + label
        params = {"backupid": f["points"][label]["backup_id"], "zoneid": f["destination_zone_id"],
                  "networkids": ",".join(m["destination"] for m in f["network_map"]),
                  "account": f["account"], "domainid": f["domain_id"], "name": name,
                  "templateid": f["template_id"], "serviceofferingid": f["service_offering_id"],
                  "startvm": "false", "preserveip": "false"}
        operation = submit_once(api, journal, label, "createVMFromBackup", params, execute)
        record = {"state": operation["state"], "backup_id": params["backupid"], "job_id": operation.get("job_id")}
        if operation["state"] == "COMPLETE":
            vm_check(api, operation["vm_id"], name, f)
            record["vm_id"] = operation["vm_id"]
            record["api_restore"] = "PASS"
        evidence["points"][label] = record
        if operation["state"] != "COMPLETE":
            break
    return evidence


def cleanup(api, f, journal):
    evidence = {}
    for label in ("older", "latest"):
        operation = journal.data["operations"].get(label)
        if not operation:
            continue
        require(operation["state"] == "COMPLETE" and operation.get("vm_id"), "CLEANUP_REQUIRES_COMPLETED_CREATE")
        key = "cleanup-" + label
        if key not in journal.data["operations"]:
            vm_check(api, operation["vm_id"], operation["params"]["name"], f)
        result = submit_once(api, journal, key, "destroyVirtualMachine", {"id": operation["vm_id"], "expunge": "false"}, True)
        evidence[label] = result["state"]
    return {"cleanup": evidence, "expunge": "NOT_TESTED", "guest_data": "NOT_TESTED", "e2e": "NOT_TESTED"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixture")
    parser.add_argument("--mode", choices=("preflight", "execute", "resume", "cleanup"), default="preflight")
    parser.add_argument("--journal-dir")
    args = parser.parse_args()
    journal = None
    try:
        require(Path(args.fixture).stat().st_size <= 65536, "FIXTURE_TOO_LARGE")
        f = json.loads(Path(args.fixture).read_text())
        fixture_check(f)
        endpoint = os.environ.get("LAYERSENTRY_CLOUDSTACK_API_URL", "")
        api = Client(endpoint, os.environ.get("LAYERSENTRY_CLOUDSTACK_API_KEY", ""), os.environ.get("LAYERSENTRY_CLOUDSTACK_SECRET_KEY", ""))
        if args.mode == "preflight":
            result = preflight(api, f)
        else:
            require(args.journal_dir, "PRIVATE_JOURNAL_DIRECTORY_REQUIRED")
            journal = Journal(args.journal_dir, f, endpoint)
            if args.mode == "cleanup":
                result = cleanup(api, f, journal)
            else:
                result = recover(api, f, journal, args.mode == "execute")
        print(json.dumps(result, sort_keys=True))
        return 0
    except GateError as exc:
        print(json.dumps({"status": "BLOCKED", "reason": str(exc), "guest_data": "NOT_TESTED", "e2e": "NOT_TESTED"}))
        return 2
    except Exception:
        print(json.dumps({"status": "BLOCKED", "reason": "INVALID_INPUT_OR_LOCAL_IO", "e2e": "NOT_TESTED"}))
        return 2
    finally:
        if journal:
            journal.close()


if __name__ == "__main__":
    raise SystemExit(main())
