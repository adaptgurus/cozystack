#!/usr/bin/env python3
"""LayerSentry read-only storage inventory and initialization safety gate.

This module intentionally performs discovery only. It never partitions, wipes,
formats, creates LVM/ZFS metadata, or creates storage pools.

Stable identity precedence:
  WWN/WWID -> NVMe NGUID -> NVMe EUI -> /dev/disk/by-id -> serial.

Kernel device names such as /dev/sdb and nvme0n1 are observations, not identity.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

_OS_MOUNTS = {"/", "/boot", "/boot/efi"}
_UNSAFE_ID_PATTERNS = (
    re.compile(r"^/dev/(?:sd[a-z]+|vd[a-z]+|xvd[a-z]+|hd[a-z]+|nvme\d+n\d+|mmcblk\d+)$"),
    re.compile(r"^(?:sd[a-z]+|vd[a-z]+|xvd[a-z]+|hd[a-z]+|nvme\d+n\d+|mmcblk\d+)$"),
    re.compile(r"^\d+:\d+$"),
)
_DISK_TYPES = {"disk", "mpath", "nvme"}
_EMPTY_VALUES = {"", "-", "none", "null", "unknown", "n/a", "na"}


def _text(value: Any) -> str:
    if value is None:
        return ""
    return str(value).strip()


def _meaningful(value: Any) -> bool:
    return _text(value).lower() not in _EMPTY_VALUES


def _normalize_token(value: Any) -> str:
    token = _text(value).strip()
    if token.lower().startswith("0x"):
        token = token[2:]
    return token.lower()


def _mountpoints(device: Dict[str, Any]) -> List[str]:
    values: List[str] = []
    for key in ("mountpoints", "mountpoint"):
        raw = device.get(key)
        if raw is None:
            continue
        if isinstance(raw, list):
            values.extend(_text(v) for v in raw if _meaningful(v))
        else:
            text = _text(raw)
            if text:
                values.extend(v.strip() for v in text.splitlines() if _meaningful(v))
    return sorted(set(values))


def _children(device: Dict[str, Any]) -> List[Dict[str, Any]]:
    value = device.get("children")
    return value if isinstance(value, list) else []


def _descendants(device: Dict[str, Any]) -> Iterable[Dict[str, Any]]:
    for child in _children(device):
        yield child
        yield from _descendants(child)


def _all_devices(top_level: Sequence[Dict[str, Any]]) -> Iterable[Dict[str, Any]]:
    for device in top_level:
        yield device
        yield from _descendants(device)


def _unsafe_identity(value: str) -> bool:
    if not value:
        return True
    return any(pattern.match(value) for pattern in _UNSAFE_ID_PATTERNS)


def _valid_by_id(alias: Any) -> bool:
    value = _text(alias)
    if not value.startswith("/dev/disk/by-id/"):
        return False
    base = os.path.basename(value)
    if not base or "-part" in base:
        return False
    return not _unsafe_identity(base)


def choose_stable_identity(device: Dict[str, Any]) -> Tuple[Optional[str], Optional[str]]:
    """Return (identity, kind) using stable-identity precedence."""
    for key in ("wwid", "wwn"):
        value = _normalize_token(device.get(key))
        if value and not _unsafe_identity(value):
            return f"wwid:{value}", "wwid"

    nguid = _normalize_token(device.get("nguid"))
    if nguid and not _unsafe_identity(nguid):
        return f"nguid:{nguid}", "nguid"

    eui = _normalize_token(device.get("eui"))
    if eui and not _unsafe_identity(eui):
        return f"eui:{eui}", "eui"

    aliases = device.get("by_id") or device.get("by-id") or []
    if isinstance(aliases, str):
        aliases = [aliases]
    for alias in sorted({_text(v) for v in aliases if _valid_by_id(v)}):
        return f"by-id:{os.path.basename(alias)}", "by-id"

    serial = _text(device.get("serial"))
    if _meaningful(serial) and not _unsafe_identity(serial):
        return f"serial:{serial}", "serial"

    return None, None


def _has_existing_data(device: Dict[str, Any]) -> Tuple[bool, List[str]]:
    reasons: List[str] = []

    children = _children(device)
    if children:
        reasons.append("partition-or-child-device-present")

    for item in [device, *_descendants(device)]:
        fstype = _text(item.get("fstype"))
        if _meaningful(fstype):
            reasons.append(f"filesystem-or-signature-present:{fstype}")

        mounts = _mountpoints(item)
        if mounts:
            reasons.append("mounted:" + ",".join(mounts))

        for key in ("holders", "slaves"):
            value = item.get(key)
            if isinstance(value, list) and value:
                reasons.append(f"{key}-present")
            elif _meaningful(value):
                reasons.append(f"{key}-present")

    return bool(reasons), sorted(set(reasons))


def _is_os_protected(device: Dict[str, Any]) -> bool:
    for item in [device, *_descendants(device)]:
        if _OS_MOUNTS.intersection(_mountpoints(item)):
            return True
    return False


def _kernel_path(device: Dict[str, Any]) -> str:
    path = _text(device.get("path"))
    if path:
        return path
    name = _text(device.get("kname") or device.get("name"))
    return f"/dev/{name}" if name else ""


def _top_level_disks(lsblk: Dict[str, Any]) -> List[Dict[str, Any]]:
    devices = lsblk.get("blockdevices")
    if not isinstance(devices, list):
        raise ValueError("input must contain a 'blockdevices' list")
    return [d for d in devices if _text(d.get("type")).lower() in _DISK_TYPES]


def inventory_from_lsblk(lsblk: Dict[str, Any], node: str = "") -> Dict[str, Any]:
    """Build a read-only inventory with fail-closed initialization eligibility."""
    disks = _top_level_disks(lsblk)

    identities = []
    for disk in disks:
        identity, _ = choose_stable_identity(disk)
        if identity:
            identities.append(identity)
    duplicate_ids = {identity for identity, count in Counter(identities).items() if count > 1}

    records: List[Dict[str, Any]] = []
    for disk in disks:
        identity, identity_kind = choose_stable_identity(disk)
        existing_data, data_reasons = _has_existing_data(disk)
        os_protected = _is_os_protected(disk)
        reasons: List[str] = list(data_reasons)

        identity_state = "stable"
        if identity is None:
            identity_state = "unsafe"
            reasons.append("no-stable-hardware-identity")
        elif identity in duplicate_ids:
            identity_state = "duplicate"
            reasons.append("duplicate-stable-identity")

        if os_protected:
            reasons.append("os-or-boot-device")

        read_only = bool(disk.get("ro"))
        if read_only:
            reasons.append("read-only-device")

        removable = bool(disk.get("rm"))
        if removable:
            reasons.append("removable-device")

        can_initialize = (
            identity_state == "stable"
            and not existing_data
            and not os_protected
            and not read_only
            and not removable
        )

        if os_protected:
            status = "protected"
        elif identity_state == "duplicate":
            status = "duplicate-identity"
        elif identity_state == "unsafe":
            status = "unsafe-identity"
        elif existing_data:
            status = "in-use-or-data-present"
        elif read_only:
            status = "read-only"
        elif removable:
            status = "removable"
        else:
            status = "candidate"

        records.append(
            {
                "node": node,
                "kernel_name": _text(disk.get("kname") or disk.get("name")),
                "path": _kernel_path(disk),
                "type": _text(disk.get("type")),
                "size_bytes": disk.get("size"),
                "model": _text(disk.get("model")),
                "serial": _text(disk.get("serial")),
                "wwn": _text(disk.get("wwn") or disk.get("wwid")),
                "identity": identity,
                "identity_kind": identity_kind,
                "identity_state": identity_state,
                "status": status,
                "existing_data": existing_data,
                "os_protected": os_protected,
                "health": _text(disk.get("health")) or "unknown",
                "can_initialize": can_initialize,
                "reasons": sorted(set(reasons)),
            }
        )

    return {
        "apiVersion": "storage.layersentry.io/v1alpha1",
        "kind": "StorageInventory",
        "node": node,
        "readOnlyDiscovery": True,
        "devices": records,
        "summary": {
            "total": len(records),
            "eligible": sum(1 for record in records if record["can_initialize"]),
            "blocked": sum(1 for record in records if not record["can_initialize"]),
        },
    }


def _by_id_aliases() -> Dict[str, List[str]]:
    aliases: Dict[str, List[str]] = {}
    by_id = Path("/dev/disk/by-id")
    if not by_id.is_dir():
        return aliases
    for path in by_id.iterdir():
        try:
            target = str(path.resolve(strict=True))
        except OSError:
            continue
        if _valid_by_id(str(path)):
            aliases.setdefault(target, []).append(str(path))
    return aliases


def collect_live_lsblk() -> Dict[str, Any]:
    """Collect live Linux block metadata using read-only commands/filesystem reads."""
    fields = [
        "NAME", "KNAME", "PATH", "TYPE", "SIZE", "MODEL", "SERIAL", "WWN",
        "FSTYPE", "MOUNTPOINTS", "RO", "RM",
    ]
    proc = subprocess.run(
        ["lsblk", "--json", "--bytes", "--output", ",".join(fields)],
        check=True,
        capture_output=True,
        text=True,
    )
    payload = json.loads(proc.stdout)
    aliases = _by_id_aliases()
    for device in _all_devices(payload.get("blockdevices", [])):
        path = _kernel_path(device)
        if path in aliases:
            device["by_id"] = sorted(set(aliases[path]))

        # lsblk versions expose NVMe identifiers inconsistently. Read sysfs
        # attributes when present; these are read-only metadata reads.
        kname = _text(device.get("kname") or device.get("name"))
        if kname.startswith("nvme"):
            sys_block = Path("/sys/class/block") / kname / "device"
            for attr in ("nguid", "eui"):
                candidate = sys_block / attr
                try:
                    value = candidate.read_text(encoding="utf-8").strip()
                except OSError:
                    continue
                if value:
                    device[attr] = value
    return payload


def _load_input(path: str) -> Dict[str, Any]:
    if path == "-":
        return json.load(sys.stdin)
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--input",
        metavar="PATH",
        help="lsblk JSON fixture; use '-' for stdin. Omit for live read-only discovery.",
    )
    parser.add_argument("--node", default=os.environ.get("NODE_NAME", ""), help="node name")
    parser.add_argument("--pretty", action="store_true", help="pretty-print JSON")
    parser.add_argument(
        "--require-all-safe",
        action="store_true",
        help="exit 3 if any discovered disk is blocked (does not initialize anything)",
    )
    args = parser.parse_args(argv)

    try:
        payload = _load_input(args.input) if args.input else collect_live_lsblk()
        inventory = inventory_from_lsblk(payload, node=args.node)
    except (OSError, ValueError, json.JSONDecodeError, subprocess.SubprocessError) as exc:
        print(f"storage inventory failed: {exc}", file=sys.stderr)
        return 2

    json.dump(inventory, sys.stdout, indent=2 if args.pretty else None, sort_keys=True)
    sys.stdout.write("\n")

    if args.require_all_safe and inventory["summary"]["blocked"]:
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
