import importlib.util
import sys
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("storage_inventory.py")
SPEC = importlib.util.spec_from_file_location("storage_inventory", MODULE_PATH)
storage_inventory = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = storage_inventory
SPEC.loader.exec_module(storage_inventory)


def inventory(*devices):
    return storage_inventory.inventory_from_lsblk({"blockdevices": list(devices)}, node="sen1")


def disk(**overrides):
    value = {
        "name": "sdb",
        "kname": "sdb",
        "path": "/dev/sdb",
        "type": "disk",
        "size": 322122547200,
        "model": "Virtual Disk",
        "serial": "",
        "wwn": "",
        "fstype": None,
        "mountpoints": [None],
        "ro": False,
        "rm": False,
    }
    value.update(overrides)
    return value


class StorageInventorySafetyTests(unittest.TestCase):
    def test_kernel_name_is_never_stable_identity(self):
        record = inventory(disk())["devices"][0]
        self.assertEqual(record["identity_state"], "unsafe")
        self.assertFalse(record["can_initialize"])
        self.assertIn("no-stable-hardware-identity", record["reasons"])

    def test_fresh_disk_with_wwid_is_candidate(self):
        record = inventory(disk(wwn="0x6000C29abcDEF123"))["devices"][0]
        self.assertEqual(record["identity"], "wwid:6000c29abcdef123")
        self.assertEqual(record["identity_state"], "stable")
        self.assertEqual(record["status"], "candidate")
        self.assertTrue(record["can_initialize"])

    def test_partition_blocks_initialization(self):
        child = {
            "name": "sdb1", "kname": "sdb1", "path": "/dev/sdb1",
            "type": "part", "fstype": None, "mountpoints": [None],
        }
        record = inventory(disk(wwn="6000c29a1", children=[child]))["devices"][0]
        self.assertTrue(record["existing_data"])
        self.assertFalse(record["can_initialize"])
        self.assertIn("partition-or-child-device-present", record["reasons"])

    def test_root_disk_is_protected_through_child_mount(self):
        child = {
            "name": "sda2", "kname": "sda2", "path": "/dev/sda2",
            "type": "part", "fstype": "ext4", "mountpoints": ["/"],
        }
        record = inventory(disk(name="sda", kname="sda", path="/dev/sda", wwn="root123", children=[child]))["devices"][0]
        self.assertTrue(record["os_protected"])
        self.assertEqual(record["status"], "protected")
        self.assertFalse(record["can_initialize"])

    def test_duplicate_wwid_blocks_both_devices(self):
        first = disk(name="sdb", kname="sdb", path="/dev/sdb", wwn="duplicate123")
        second = disk(name="sdc", kname="sdc", path="/dev/sdc", wwn="duplicate123")
        records = inventory(first, second)["devices"]
        self.assertEqual([r["identity_state"] for r in records], ["duplicate", "duplicate"])
        self.assertTrue(all(not r["can_initialize"] for r in records))

    def test_nvme_nguid_is_accepted(self):
        record = inventory(disk(name="nvme0n1", kname="nvme0n1", path="/dev/nvme0n1",
                                type="disk", nguid="E8238FA6BF530001001B448B4E123456"))["devices"][0]
        self.assertEqual(record["identity_kind"], "nguid")
        self.assertTrue(record["can_initialize"])

    def test_by_id_alias_is_accepted(self):
        record = inventory(disk(by_id=["/dev/disk/by-id/scsi-3600508b400105e210000900000490000"]))["devices"][0]
        self.assertEqual(record["identity_kind"], "by-id")
        self.assertTrue(record["can_initialize"])

    def test_mounted_filesystem_blocks_initialization(self):
        record = inventory(disk(wwn="mounted123", fstype="xfs", mountpoints=["/data"]))["devices"][0]
        self.assertTrue(record["existing_data"])
        self.assertFalse(record["can_initialize"])
        self.assertTrue(any(reason.startswith("mounted:") for reason in record["reasons"]))

    def test_lvm_signature_blocks_initialization(self):
        record = inventory(disk(wwn="lvm123", fstype="LVM2_member"))["devices"][0]
        self.assertFalse(record["can_initialize"])
        self.assertIn("filesystem-or-signature-present:LVM2_member", record["reasons"])

    def test_serial_is_accepted_only_as_stable_fallback(self):
        record = inventory(disk(serial="HYPERV-STABLE-12345"))["devices"][0]
        self.assertEqual(record["identity"], "serial:HYPERV-STABLE-12345")
        self.assertEqual(record["identity_kind"], "serial")
        self.assertTrue(record["can_initialize"])

    def test_read_only_or_removable_devices_are_blocked(self):
        ro = inventory(disk(wwn="readonly123", ro=True))["devices"][0]
        rm = inventory(disk(wwn="removable123", rm=True))["devices"][0]
        self.assertFalse(ro["can_initialize"])
        self.assertFalse(rm["can_initialize"])

    def test_require_all_safe_is_fail_closed_semantics(self):
        data = inventory(disk())
        self.assertEqual(data["summary"], {"total": 1, "eligible": 0, "blocked": 1})


if __name__ == "__main__":
    unittest.main()
