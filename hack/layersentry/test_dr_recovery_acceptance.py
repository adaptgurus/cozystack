#!/usr/bin/env python3
"""Offline behavioral tests; no credentials, network or live VM mutations."""

import copy
import json
import tempfile
import unittest
from pathlib import Path

import dr_recovery_acceptance as dr


def uid(number):
    return f"00000000-0000-4000-8000-{number:012d}"


def fixture():
    return {"run_id": uid(1), "source_vm_id": uid(2), "source_zone_id": uid(3),
            "destination_zone_id": uid(4), "account_id": uid(5), "account": "test-account",
            "domain_id": uid(6), "repository_id": uid(7), "offering_id": uid(8),
            "template_id": uid(9), "service_offering_id": uid(10),
            "network_map": [{"source": uid(11), "destination": uid(12)}],
            "points": {"older": {"backup_id": uid(13), "disk_hashes": {"0": "a" * 64, "1": "b" * 64}},
                       "latest": {"backup_id": uid(14), "disk_hashes": {"0": "c" * 64, "1": "d" * 64}}}}


class API:
    def __init__(self, f):
        self.f = f
        self.calls = []
        self.rows = {}
        self.job_status = 1
        self.transport_failure = False
        owner = {"account": f["account"], "accountid": f["account_id"], "domainid": f["domain_id"]}
        for command, kind, resource in [
            ("listAccounts", "account", {"id": f["account_id"], "name": f["account"], "domainid": f["domain_id"], "state": "enabled"}),
            ("listZones", "zone", {"id": f["source_zone_id"], "allocationstate": "Enabled"}),
            ("listZones", "zone", {"id": f["destination_zone_id"], "allocationstate": "Enabled"}),
            ("listVirtualMachines", "virtualmachine", {"id": f["source_vm_id"], **owner, "zoneid": f["source_zone_id"], "hypervisor": "KVM", "state": "Stopped", "nic": [{"networkid": uid(11)}]}),
            ("listNetworks", "network", {"id": uid(12), **owner, "zoneid": f["destination_zone_id"], "state": "Implemented"}),
            ("listBackupRepositories", "backuprepository", {"id": f["repository_id"], "zoneid": f["source_zone_id"], "provider": "nas", "crosszoneinstancecreation": True}),
            ("listBackupOfferings", "backupoffering", {"id": f["offering_id"], "zoneid": f["source_zone_id"], "provider": "nas", "externalid": f["repository_id"]}),
            ("listTemplates", "template", {"id": f["template_id"], "isready": True, "hypervisor": "KVM"}),
            ("listServiceOfferings", "serviceoffering", {"id": f["service_offering_id"]}),
        ]:
            self.rows[(command, resource["id"])] = {kind: [resource]}
        for label, day in [("older", 1), ("latest", 2)]:
            backup_id = f["points"][label]["backup_id"]
            self.rows[("listBackups", backup_id)] = {"backup": [{"id": backup_id, **owner,
                "virtualmachineid": f["source_vm_id"], "zoneid": f["source_zone_id"],
                "backupofferingid": f["offering_id"], "status": "BackedUp",
                "created": f"2026-09-0{day}T12:00:00+0000", "volumes": json.dumps([{"deviceId": 0}, {"deviceId": 1}])}]}
        self.jobs = {}
        self.owner = owner

    def __call__(self, command, **params):
        self.calls.append((command, params))
        if command == "createVMFromBackup":
            number = len(self.jobs) + 100
            job_id, vm_id = uid(number), uid(number + 100)
            self.jobs[job_id] = {"virtualmachine": {"id": vm_id}}
            self.rows[("listVirtualMachines", vm_id)] = {"virtualmachine": [{"id": vm_id, **self.owner,
                "zoneid": params["zoneid"], "name": params["name"], "state": "Stopped", "nic": [{"networkid": uid(12)}]}]}
            if self.transport_failure:
                raise dr.GateError("API_TRANSPORT_OR_RESPONSE_FAILURE")
            return {"jobid": job_id}
        if command == "destroyVirtualMachine":
            job_id = uid(len(self.jobs) + 100)
            self.jobs[job_id] = {"success": True}
            return {"jobid": job_id}
        if command == "queryAsyncJobResult":
            return {"jobstatus": self.job_status, "jobresult": self.jobs[params["jobid"]]}
        return copy.deepcopy(self.rows.get((command, params["id"]), {}))

    def mutations(self):
        return [(c, p) for c, p in self.calls if c in {"createVMFromBackup", "destroyVirtualMachine"}]


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.f = fixture()
        self.api = API(self.f)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.journal = dr.Journal(self.temp.name, self.f, "https://cloud.example/client/api")
        self.addCleanup(self.journal.close)

    def test_preflight_is_read_only_and_never_claims_guest_pass(self):
        result = dr.preflight(self.api, self.f)
        self.assertEqual(result["api_preflight"], "PASS")
        self.assertEqual(result["guest_data"], "NOT_TESTED")
        self.assertEqual(self.api.mutations(), [])

    def test_invalid_fixture_denied_before_api(self):
        for mutate in [lambda f: f.update(source_vm_id="bogus"),
                       lambda f: f.update(network_map=[]),
                       lambda f: f.update(destination_zone_id=f["source_zone_id"]),
                       lambda f: f.update(password="secret"),
                       lambda f: f["points"]["latest"].update(backup_id=f["points"]["older"]["backup_id"]),
                       lambda f: f["points"]["latest"].update(disk_hashes=f["points"]["older"]["disk_hashes"])]:
            f = copy.deepcopy(self.f)
            mutate(f)
            with self.assertRaises(dr.GateError):
                dr.preflight(self.api, f)
        self.assertEqual(self.api.calls, [])

    def test_wrong_zone_missing_mapping_unauthorized_and_bad_state(self):
        cases = [("listNetworks", uid(12), "network", "zoneid", uid(3)),
                 ("listNetworks", uid(12), "network", "account", "foreign"),
                 ("listVirtualMachines", uid(2), "virtualmachine", "state", "Running"),
                 ("listVirtualMachines", uid(2), "virtualmachine", "nic", [{"networkid": uid(99)}]),
                 ("listBackups", uid(13), "backup", "status", "BackingUp"),
                 ("listBackups", uid(13), "backup", "accountid", uid(99)),
                 ("listBackupRepositories", uid(7), "backuprepository", "crosszoneinstancecreation", False)]
        for command, resource_id, kind, field, value in cases:
            api = API(self.f)
            api.rows[(command, resource_id)][kind][0][field] = value
            with self.subTest(field=field), self.assertRaises(dr.GateError):
                dr.recover(api, self.f, self.journal, execute=True)
            self.assertEqual(api.mutations(), [])
        del self.api.rows[("listBackups", uid(13))]
        with self.assertRaisesRegex(dr.GateError, "RESOURCE_MISSING_OR_UNAUTHORIZED"):
            dr.preflight(self.api, self.f)

    def test_distinct_checkpoints_create_stopped_clones_once(self):
        result = dr.recover(self.api, self.f, self.journal, execute=True)
        calls = self.api.mutations()
        self.assertEqual([p["backupid"] for _, p in calls], [uid(13), uid(14)])
        self.assertTrue(all(p["startvm"] == "false" for _, p in calls))
        self.assertTrue(all(p["networkids"] == uid(12) for _, p in calls))
        self.assertEqual(result["e2e"], "NOT_TESTED")
        dr.recover(self.api, self.f, self.journal, execute=True)
        self.assertEqual(len(self.api.mutations()), 2)

    def test_uncertain_submission_persists_intent_and_never_retries(self):
        self.api.transport_failure = True
        with self.assertRaises(dr.GateError):
            dr.recover(self.api, self.f, self.journal, execute=True)
        state = json.loads((Path(self.temp.name) / "journal.json").read_text())
        self.assertEqual(state["operations"]["older"]["state"], "SUBMITTING")
        self.api.transport_failure = False
        with self.assertRaisesRegex(dr.GateError, "SUBMISSION_UNCERTAIN"):
            dr.recover(self.api, self.f, self.journal, execute=True)
        self.assertEqual(len(self.api.mutations()), 1)

    def test_pending_job_resume_queries_exact_id_without_duplicate(self):
        self.api.job_status = 0
        dr.recover(self.api, self.f, self.journal, execute=True)
        job_id = self.journal.data["operations"]["older"]["job_id"]
        dr.recover(self.api, self.f, self.journal, execute=False)
        self.assertEqual(len(self.api.mutations()), 1)
        queries = [p["jobid"] for c, p in self.api.calls if c == "queryAsyncJobResult"]
        self.assertEqual(queries, [job_id, job_id])
        self.api.job_status = 1
        result = dr.recover(self.api, self.f, self.journal, execute=False)
        self.assertEqual(result["points"]["latest"]["state"], "NOT_SUBMITTED")
        self.assertEqual(len(self.api.mutations()), 1)
        dr.recover(self.api, self.f, self.journal, execute=True)
        self.assertEqual(len(self.api.mutations()), 2)

    def test_failed_job_never_recreates(self):
        self.api.job_status = 2
        for _ in range(2):
            with self.assertRaisesRegex(dr.GateError, "ASYNC_JOB_FAILED"):
                dr.recover(self.api, self.f, self.journal, execute=True)
        self.assertEqual(len(self.api.mutations()), 1)

    def test_job_query_transport_failure_preserves_exact_job_for_resume(self):
        def interrupted(command, **params):
            if command == "queryAsyncJobResult":
                raise dr.GateError("API_TRANSPORT_OR_RESPONSE_FAILURE")
            return self.api(command, **params)

        with self.assertRaises(dr.GateError):
            dr.recover(interrupted, self.f, self.journal, execute=True)
        state = json.loads((Path(self.temp.name) / "journal.json").read_text())
        self.assertEqual(state["operations"]["older"]["state"], "SUBMITTED")
        job_id = state["operations"]["older"]["job_id"]
        result = dr.recover(self.api, self.f, self.journal, execute=False)
        self.assertEqual(result["points"]["older"]["job_id"], job_id)
        self.assertEqual(result["points"]["older"]["state"], "COMPLETE")
        self.assertEqual(len(self.api.mutations()), 1)

    def test_wrong_checkpoint_order_or_missing_disk_prevents_mutation(self):
        self.api.rows[("listBackups", uid(14))]["backup"][0]["created"] = "2026-08-01T12:00:00+0000"
        with self.assertRaisesRegex(dr.GateError, "CHECKPOINT_ORDER_MISMATCH"):
            dr.recover(self.api, self.f, self.journal, execute=True)
        self.api.rows[("listBackups", uid(14))]["backup"][0]["volumes"] = "[]"
        with self.assertRaisesRegex(dr.GateError, "BACKUP_DISK_MAPPING_MISMATCH"):
            dr.recover(self.api, self.f, self.journal, execute=True)
        self.assertEqual(self.api.mutations(), [])

    def test_cleanup_only_recorded_recovery_ids_and_not_expunge(self):
        dr.recover(self.api, self.f, self.journal, execute=True)
        expected = {self.journal.data["operations"][x]["vm_id"] for x in ("older", "latest")}
        dr.cleanup(self.api, self.f, self.journal)
        dr.cleanup(self.api, self.f, self.journal)
        deletes = [p for c, p in self.api.mutations() if c == "destroyVirtualMachine"]
        self.assertEqual({p["id"] for p in deletes}, expected)
        self.assertEqual(len(deletes), 2)
        self.assertTrue(all(p["expunge"] == "false" for p in deletes))
        self.assertNotIn(self.f["source_vm_id"], expected)

    def test_cleanup_refuses_changed_clone_identity(self):
        dr.recover(self.api, self.f, self.journal, execute=True)
        vm_id = self.journal.data["operations"]["older"]["vm_id"]
        self.api.rows[("listVirtualMachines", vm_id)]["virtualmachine"][0]["account"] = "foreign"
        with self.assertRaisesRegex(dr.GateError, "OWNER_MISMATCH"):
            dr.cleanup(self.api, self.f, self.journal)
        self.assertEqual(len(self.api.mutations()), 2)

    def test_journal_lock_rejects_parallel_runner(self):
        with self.assertRaisesRegex(dr.GateError, "JOURNAL_BUSY"):
            dr.Journal(self.temp.name, self.f, "https://cloud.example/client/api")

    def test_endpoint_rejects_remote_plaintext_and_credentials_in_url(self):
        for endpoint in ("http://10.0.0.1/client/api", "https://user:pass@example.com/client/api", "https://example.com/client/api?secret=x"):
            with self.assertRaises(dr.GateError):
                dr.Client(endpoint, "key", "secret")


if __name__ == "__main__":
    unittest.main()
