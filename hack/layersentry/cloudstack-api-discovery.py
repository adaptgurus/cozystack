#!/usr/bin/env python3
"""Read-only discovery of a fresh local CloudStack 4.22.1.1 installation.

No CloudStack mutation APIs are called. The helper first tries the documented
fresh-install admin credential locally, never prints the password/session key,
and emits only topology/capability/offering metadata required for the next
single-node POC phase.
"""
from __future__ import annotations

import http.cookiejar
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

BASE = "http://127.0.0.1:8080/client/api"
DEFAULT_ADMIN_USER = "admin"
DEFAULT_ADMIN_PASSWORD = "password"
TIMEOUT = 20

jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))


def request(params: dict[str, object], *, method: str = "GET") -> dict:
    clean = {k: str(v) for k, v in params.items() if v is not None}
    encoded = urllib.parse.urlencode(clean).encode()
    if method == "POST":
        req = urllib.request.Request(BASE, data=encoded, method="POST")
    else:
        req = urllib.request.Request(BASE + "?" + encoded.decode(), method="GET")
    req.add_header("Accept", "application/json")
    try:
        with opener.open(req, timeout=TIMEOUT) as res:
            data = res.read()
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")[:1200]
        raise RuntimeError(f"HTTP {exc.code}: {body}") from exc
    return json.loads(data.decode("utf-8"))


def login() -> str:
    payload = request(
        {
            "command": "login",
            "username": DEFAULT_ADMIN_USER,
            "password": DEFAULT_ADMIN_PASSWORD,
            "response": "json",
        },
        method="POST",
    )
    lr = payload.get("loginresponse", {})
    key = lr.get("sessionkey")
    if not key:
        err = lr.get("errortext") or lr.get("errorcode") or "no session key"
        raise RuntimeError(f"fresh-install admin login failed: {err}")
    print("LOGIN=PASS")
    print(f"ACCOUNT={lr.get('account', '')}")
    print(f"DOMAIN={lr.get('domainname', '')}")
    print(f"USER_ID_PRESENT={'yes' if lr.get('userid') else 'no'}")
    return str(key)


def api(session: str, command: str, **params: object) -> dict:
    q = {"command": command, "response": "json", "sessionkey": session}
    q.update(params)
    return request(q)


def response_object(payload: dict, command: str) -> dict:
    return payload.get(command.lower() + "response", {})


def print_count(session: str, command: str, item_key: str, **params: object) -> list:
    payload = api(session, command, **params)
    r = response_object(payload, command)
    items = r.get(item_key) or []
    if isinstance(items, dict):
        items = [items]
    print(f"{command.upper()}_COUNT={r.get('count', len(items))}")
    return items


def services(offering: dict) -> list[str]:
    out: list[str] = []
    for svc in offering.get("service") or []:
        if isinstance(svc, dict):
            name = svc.get("name")
            if name:
                out.append(str(name))
        elif svc:
            out.append(str(svc))
    return sorted(set(out))


def main() -> int:
    session = login()

    print("\n===== TOPOLOGY =====")
    zones = print_count(session, "listZones", "zone", listall="true")
    pods = print_count(session, "listPods", "pod", listall="true")
    clusters = print_count(session, "listClusters", "cluster", listall="true")
    hosts = print_count(session, "listHosts", "host", listall="true")
    stores = print_count(session, "listStoragePools", "storagepool", listall="true")
    images = print_count(session, "listImageStores", "imagestore", listall="true")
    if any((zones, pods, clusters, hosts, stores, images)):
        print("FRESH_TOPOLOGY=NO")
    else:
        print("FRESH_TOPOLOGY=YES")

    print("\n===== HYPERVISORS =====")
    hypers = print_count(session, "listHypervisors", "hypervisor")
    for h in hypers:
        if isinstance(h, dict):
            print("HYPERVISOR=" + str(h.get("name") or h.get("hypervisor") or h))
        else:
            print("HYPERVISOR=" + str(h))

    print("\n===== CAPABILITIES =====")
    cap = response_object(api(session, "listCapabilities"), "listCapabilities").get("capability") or {}
    keys = [
        "securitygroupsenabled",
        "userpublictemplateenabled",
        "cloudstackversion",
        "kvm.snapshot.enabled",
    ]
    for key in keys:
        if key in cap:
            print(f"CAP_{key}={cap.get(key)}")
    if cap:
        print("CAPABILITY_OBJECT_PRESENT=yes")

    print("\n===== NETWORK OFFERINGS =====")
    offerings = print_count(
        session,
        "listNetworkOfferings",
        "networkoffering",
        listall="true",
        page=1,
        pagesize=500,
    )
    candidates = []
    for o in offerings:
        svc = services(o)
        record = {
            "id": o.get("id"),
            "name": o.get("name"),
            "displaytext": o.get("displaytext"),
            "state": o.get("state"),
            "guestiptype": o.get("guestiptype"),
            "traffictype": o.get("traffictype"),
            "specifyvlan": o.get("specifyvlan"),
            "availability": o.get("availability"),
            "conservemode": o.get("conservemode"),
            "service": svc,
        }
        if (
            str(o.get("state", "")).lower() == "enabled"
            and str(o.get("guestiptype", "")).lower() == "shared"
            and any(s.lower() == "securitygroup" for s in svc)
        ):
            candidates.append(record)
        if any(s.lower() == "securitygroup" for s in svc):
            print("SG_OFFERING=" + json.dumps(record, sort_keys=True, separators=(",", ":")))

    print(f"BASIC_SG_CANDIDATE_COUNT={len(candidates)}")
    for c in candidates:
        print("BASIC_SG_CANDIDATE=" + json.dumps(c, sort_keys=True, separators=(",", ":")))

    print("\n===== CONFIGURATION =====")
    for name in (
        "kvm.host.discovery.ssh.port",
        "system.vm.use.local.storage",
        "secstorage.allowed.internal.sites",
    ):
        payload = api(session, "listConfigurations", name=name, listall="true")
        configs = response_object(payload, "listConfigurations").get("configuration") or []
        if configs:
            c = configs[0]
            print(f"CONFIG_{name}={c.get('value', '')}")
        else:
            print(f"CONFIG_{name}=NOT_RETURNED")

    print("\n===== PROVIDERS =====")
    try:
        providers = print_count(session, "listStorageProviders", "storageprovider", type="PRIMARY")
        for p in providers:
            if isinstance(p, dict):
                print("PRIMARY_PROVIDER=" + str(p.get("name") or p.get("type") or p))
    except Exception as exc:  # discovery only; command surface varies by release
        print(f"PRIMARY_PROVIDER_QUERY=UNAVAILABLE:{type(exc).__name__}")

    print("\nDISCOVERY_COMPLETE")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"DISCOVERY_ERROR={type(exc).__name__}:{exc}", file=sys.stderr)
        raise SystemExit(1)
