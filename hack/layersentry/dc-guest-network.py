#!/usr/bin/env python3
"""Fixed DC guest bridge/traffic label, with intent-before-action and no replay."""
import json
import re
import subprocess

from dr_recovery_acceptance import GateError, require
from dc_native_storage_registration import preflight, rows, exact, ZONE

MAC = '02:29:ba:17:6b:81'
BRIDGE = 'ls-guest0'
BRIDGE_UUID = 'd59248dc-25a2-5590-8332-2f9df8f5621a'
PORT_UUID = '8bb9f0e2-3d8a-50e7-8573-e27ff0e14f5d'
PHYSICAL = 'a3182ad1-7de2-45e3-81ce-5ccbf9280421'
GUEST = 'd33d6182-41c1-4217-9116-bf8234fc1b57'
MANAGEMENT = '5f6ff203-7004-42e3-a4f6-10b2aa23ed98'
# Exact unused profile observed after our owned disconnected NIC was added.
DEFAULT_UUID = '1106aace-e8ff-39a7-8d76-7a5bec119e94'
DEFAULT_OPERATION = 'disable-default-autoconnect'


def run(args):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=30,
                           env={'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LC_ALL': 'C'})
        require(p.returncode == 0 and len(p.stdout) <= 1048576, 'GUEST_COMMAND_FAILED')
        return p.stdout
    except (OSError, subprocess.TimeoutExpired, UnicodeError):
        raise GateError('GUEST_COMMAND_FAILED') from None


def read_json(args):
    value = json.loads(run(args))
    require(isinstance(value, list) and len(value) <= 256, 'GUEST_INVENTORY_INVALID')
    return value


def management_identity():
    links = read_json(['ip', '-j', 'link', 'show'])
    byname = {r['ifname']: r for r in links}
    require('cloudbr0' in byname and 'eth0' in byname, 'MANAGEMENT_LINK_MISSING')
    require(byname['eth0'].get('master') == 'cloudbr0'
            and byname['eth0'].get('address', '').lower() == '00:15:5d:00:39:0a', 'MANAGEMENT_PORT_CHANGED')
    addresses = read_json(['ip', '-j', '-4', 'address', 'show', 'dev', 'cloudbr0'])
    ips = sorted((a.get('local'), a.get('prefixlen')) for row in addresses for a in row.get('addr_info', []))
    require(ips == [('10.10.10.14', 24)], 'MANAGEMENT_ADDRESS_CHANGED')
    routes = read_json(['ip', '-j', '-4', 'route', 'show', 'table', 'main'])
    defaults = [r for r in routes if r.get('dst') == 'default']
    require(len(defaults) == 1 and defaults[0].get('dev') == 'cloudbr0'
            and defaults[0].get('gateway') == '10.10.10.1', 'MANAGEMENT_DEFAULT_CHANGED')
    # Compare all main IPv4 routes before/after, including metrics and source addresses.
    return {'routes': sorted(json.dumps(r, sort_keys=True) for r in routes), 'addresses': ips,
            'managementPortIndex': byname['eth0']['ifindex'], 'managementBridgeIndex': byname['cloudbr0']['ifindex']}


def guest_device(required=False):
    links = read_json(['ip', '-j', 'link', 'show'])
    found = [r for r in links if r.get('address', '').lower() == MAC and r.get('ifname') != BRIDGE]
    require(len(found) <= 1, 'DUPLICATE_GUEST_MAC')
    if not found:
        require(not required, 'GUEST_NIC_NOT_OBSERVED')
        return None
    device = found[0]['ifname']
    require(re.fullmatch(r'[A-Za-z0-9_.-]{1,15}', device) and device not in ('eth0', 'cloudbr0', 'cloud0', 'lo'), 'GUEST_DEVICE_CONFLICT')
    require(found[0].get('master') in (None, BRIDGE), 'GUEST_DEVICE_ALREADY_ENSLAVED')
    no_layer3(device)
    return device


def no_layer3(device):
    entries = read_json(['ip', '-j', 'address', 'show', 'dev', device])
    require(len(entries) == 1 and not entries[0].get('addr_info'), 'GUEST_DEVICE_HAS_LAYER3')


def profiles():
    ids = run(['nmcli', '-g', 'UUID', 'connection', 'show']).splitlines()
    require(len(ids) <= 128 and len(set(ids)) == len(ids)
            and all(re.fullmatch(r'[0-9a-f-]{36}', i) for i in ids), 'NM_PROFILE_LIST_INVALID')
    return ids


def prop(identity, field):
    return run(['nmcli', '-g', field, '-e', 'no', 'connection', 'show', 'uuid', identity]).strip()


def desired_profile(key, device):
    if key == 'bridge':
        return {'connection.id': 'layersentry-dc-guest-bridge', 'connection.uuid': BRIDGE_UUID,
                'connection.type': 'bridge', 'connection.interface-name': BRIDGE,
                'connection.autoconnect': 'yes', 'ipv4.method': 'disabled', 'ipv6.method': 'disabled', 'bridge.stp': 'no'}
    return {'connection.id': 'layersentry-dc-guest-port', 'connection.uuid': PORT_UUID,
            'connection.type': '802-3-ethernet', 'connection.interface-name': device,
            'connection.autoconnect': 'yes', 'connection.master': BRIDGE_UUID,
            'connection.slave-type': 'bridge', '802-3-ethernet.mac-address': MAC.upper()}


def profile_observed(key, device):
    desired = desired_profile(key, device)
    identity = desired['connection.uuid']
    if identity not in profiles():
        return False
    for field, value in desired.items():
        require(prop(identity, field) == value, 'OWNED_NM_PROFILE_DRIFT')
    return True


def default_profile_autoconnect(device):
    require(device == 'eth1', 'DEFAULT_PROFILE_DEVICE_CHANGED')
    expected = {'connection.id': 'Wired connection 1', 'connection.uuid': DEFAULT_UUID,
                'connection.type': '802-3-ethernet', 'connection.interface-name': device,
                'connection.master': '', 'connection.slave-type': '', '802-3-ethernet.mac-address': '',
                'ipv4.method': 'auto', 'ipv6.method': 'auto', 'connection.timestamp': '0',
                'GENERAL.STATE': '', 'GENERAL.DEVICES': ''}
    for field, value in expected.items():
        require(prop(DEFAULT_UUID, field) == value, 'DEFAULT_PROFILE_IDENTITY_OR_ACTIVITY_CHANGED')
    autoconnect = prop(DEFAULT_UUID, 'connection.autoconnect')
    require(autoconnect in ('yes', 'no'), 'DEFAULT_PROFILE_AUTOCONNECT_UNKNOWN')
    return autoconnect


def disable_default_autoconnect(device, journal):
    if DEFAULT_UUID not in profiles():
        require(DEFAULT_OPERATION not in journal.data['operations'], 'JOURNALED_DEFAULT_PROFILE_DISAPPEARED')
        return
    # Preserve this unused profile. Only its autoconnect bit is changed; no
    # deletion, activation, renaming, or conversion into an owned port occurs.
    specification = {'uuid': DEFAULT_UUID, 'device': device, 'guestMac': MAC,
                     'originalAutoconnect': 'yes', 'desiredAutoconnect': 'no'}
    once(journal, DEFAULT_OPERATION, specification,
         lambda: default_profile_autoconnect(device) == 'no',
         lambda: run(['nmcli', 'connection', 'modify', 'uuid', DEFAULT_UUID, 'connection.autoconnect', 'no']))


def no_profile_collisions(device, operations, allow_reviewed_default=False):
    for identity in profiles():
        name, interface = prop(identity, 'connection.id'), prop(identity, 'connection.interface-name')
        if identity == DEFAULT_UUID and (allow_reviewed_default or DEFAULT_OPERATION in operations):
            autoconnect = default_profile_autoconnect(device)
            if not allow_reviewed_default:
                require(autoconnect == 'no' and operations[DEFAULT_OPERATION].get('state') == 'RECONCILED',
                        'DEFAULT_PROFILE_NOT_RECONCILED')
        elif identity in (BRIDGE_UUID, PORT_UUID):
            key = 'bridge' if identity == BRIDGE_UUID else 'port'
            require(key in operations, 'UNJOURNALED_OWNED_PROFILE')
            profile_observed(key, device)
        else:
            require(name not in ('layersentry-dc-guest-bridge', 'layersentry-dc-guest-port')
                    and interface not in (BRIDGE, device), 'UNOWNED_NM_PROFILE_COLLISION')
    links = read_json(['ip', '-j', 'link', 'show'])
    if any(r['ifname'] == BRIDGE for r in links):
        require('bridge' in operations, 'UNOWNED_BRIDGE_EXISTS')


def once(journal, key, specification, observe, submit):
    operations = journal.data['operations']
    prior = operations.get(key)
    if prior:
        require(prior.get('specification') == specification, 'OPERATION_BINDING_CHANGED')
    if observe():
        require(prior is not None, 'UNJOURNALED_EXISTING_MUTATION')
        prior['state'] = 'RECONCILED'
        journal.save()
        return
    # Owned autoconnect profiles may activate when Hyper-V supplies carrier.
    # ARMED records this expected side effect before Connect; it is not a submitted nmcli activation.
    require(prior is None or (key == 'activate' and prior.get('state') == 'ARMED'), 'UNCERTAIN_OPERATION_NO_REPLAY')
    operations[key] = {'specification': specification, 'state': 'SUBMITTING'}
    journal.save()
    try:
        submit()
    except Exception:
        operations[key]['state'] = 'SUBMISSION_UNCERTAIN'
        journal.save()
    require(observe(), 'UNCERTAIN_OPERATION_NO_REPLAY')
    operations[key]['state'] = 'RECONCILED'
    journal.save()


def bridge_observed(device):
    links = read_json(['ip', '-j', '-d', 'link', 'show'])
    bridge = [r for r in links if r['ifname'] == BRIDGE]
    ports = [r['ifname'] for r in links if r.get('master') == BRIDGE]
    if not bridge or ports != [device]:
        return False
    require(bridge[0].get('linkinfo', {}).get('info_kind') == 'bridge', 'NOT_A_BRIDGE')
    require('UP' in bridge[0].get('flags', []), 'BRIDGE_NOT_ADMIN_UP')
    no_layer3(BRIDGE)
    no_layer3(device)
    return True


def api_scope(api):
    preflight(api)  # Includes exact Basic Disabled Zone, Pod, cluster and Up host.
    physical = exact(api, 'listPhysicalNetworks', 'physicalnetwork', PHYSICAL)
    require(physical.get('zoneid') == ZONE and physical.get('state') == 'Enabled', 'PHYSICAL_NETWORK_CHANGED')
    traffic = rows(api, 'listTrafficTypes', 'traffictype', physicalnetworkid=PHYSICAL)
    require({r.get('id') for r in traffic} == {GUEST, MANAGEMENT}, 'TRAFFIC_SCOPE_CHANGED')
    found = {r['id']: r for r in traffic}
    require(found[MANAGEMENT].get('traffictype') == 'Management' and found[MANAGEMENT].get('kvmnetworklabel') is None,
            'MANAGEMENT_TRAFFIC_CHANGED')
    require(found[GUEST].get('traffictype') == 'Guest' and found[GUEST].get('physicalnetworkid') == PHYSICAL
            and found[GUEST].get('kvmnetworklabel') in (None, BRIDGE), 'GUEST_TRAFFIC_CHANGED')
    for command, kind in (('listSystemVms', 'systemvm'), ('listVirtualMachines', 'virtualmachine')):
        require(not rows(api, command, kind, zoneid=ZONE), 'SOURCE_ZONE_HAS_VMS')
    return found[GUEST].get('kvmnetworklabel')


def execute(api, journal, phase='Plan'):
    require(phase in ('Plan', 'Bridge', 'Label'), 'INVALID_PHASE')
    before = management_identity()
    label = api_scope(api)
    device = guest_device(required=phase != 'Plan')
    evidence = {'schema': 1, 'target': '10.10.10.14', 'phase': phase, 'zoneEnabled': False,
                'device': device, 'guestMac': MAC, 'bridge': BRIDGE, 'guestLabel': label,
                'managementPreserved': True, 'gatewayRouting': 'NOT_ESTABLISHED', 'status': 'PLAN'}
    if phase == 'Plan':
        no_profile_collisions(device, journal.data['operations'] if journal else {})
        evidence['nicStatus'] = 'OBSERVED' if device else 'NOT_ADDED'
        evidence['plannedOperations'] = ['ADD_DISCONNECTED_GUEST_NIC', 'CREATE_NO_L3_BRIDGE_AND_PORT', 'CONNECT_GUEST_NIC', 'UPDATE_GUEST_LABEL']
        return evidence
    require(journal is not None, 'PERSISTENT_JOURNAL_REQUIRED')
    if phase == 'Bridge':
        # Check every unrelated collision before changing the exact reviewed
        # inactive default profile. MAC/L3 and native scope were checked above.
        no_profile_collisions(device, journal.data['operations'], allow_reviewed_default=True)
        disable_default_autoconnect(device, journal)
        require(management_identity() == before, 'MANAGEMENT_DRIFT_AFTER_DEFAULT_PROFILE')
    no_profile_collisions(device, journal.data['operations'])
    if phase == 'Bridge':
        for key in ('bridge', 'port'):
            spec = desired_profile(key, device)
            args = ['nmcli', 'connection', 'add', 'type', 'bridge' if key == 'bridge' else 'ethernet']
            for field, value in spec.items():
                if field != 'connection.type':
                    args += [field, value]
            once(journal, key, spec, lambda k=key: profile_observed(k, device), lambda a=args: run(a))
            require(management_identity() == before, 'MANAGEMENT_DRIFT_AFTER_PROFILE')
        if 'activate' not in journal.data['operations']:
            journal.data['operations']['activate'] = {'specification': {'port': PORT_UUID, 'bridge': BRIDGE_UUID}, 'state': 'ARMED'}
            journal.save()
    else:
        require(profile_observed('bridge', device) and profile_observed('port', device), 'PROFILES_NOT_READY')
        # The host connects only after these no-L3 profiles exist. Carrier can now activate the port.
        once(journal, 'activate', {'port': PORT_UUID, 'bridge': BRIDGE_UUID},
             lambda: bridge_observed(device), lambda: run(['nmcli', '--wait', '20', 'connection', 'up', 'uuid', PORT_UUID]))
        require(bridge_observed(device) and profile_observed('bridge', device) and profile_observed('port', device), 'BRIDGE_NOT_READY')
        once(journal, 'label', {'id': GUEST, 'kvmnetworklabel': BRIDGE},
             lambda: api_scope(api) == BRIDGE, lambda: api('updateTrafficType', id=GUEST, kvmnetworklabel=BRIDGE))
        evidence['guestLabel'] = api_scope(api)
    require(management_identity() == before, 'MANAGEMENT_DRIFT_AFTER_OPERATION')
    api_scope(api)
    evidence['status'] = 'RECONCILED'
    return evidence
