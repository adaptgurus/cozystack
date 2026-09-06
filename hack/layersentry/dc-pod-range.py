#!/usr/bin/env python3
"""Native-only fixed DC Pod exclusion; never edits SQL, DHCP or Zone state."""
import time

from dr_recovery_acceptance import GateError, identifier, require
from dc_native_storage_registration import POD, ZONE, preflight, exact, rows

OLD = ('10.10.10.2', '10.10.10.254')
NEW = ('10.10.10.2', '10.10.10.9')
PARAMS = {'podid': POD, 'currentstartip': OLD[0], 'currentendip': OLD[1],
          'newstartip': NEW[0], 'newendip': NEW[1]}


def observe(api):
    preflight(api)
    pod = exact(api, 'listPods', 'pod', POD)
    require(pod.get('gateway') == '10.10.10.1' and pod.get('netmask') == '255.255.255.0', 'POD_SUBNET_CHANGED')
    ranges = pod.get('ipranges')
    require(isinstance(ranges, list) and len(ranges) == 1, 'POD_RANGE_COUNT_CHANGED')
    item = ranges[0]
    # Exact native ApiResponseHelper populates role and VLAN; nested gateway/CIDR are not populated.
    require(item.get('forsystemvms') == '0' and item.get('vlanid') == 'vlan://untagged', 'POD_RANGE_ROLE_OR_VLAN_CHANGED')
    endpoints = (item.get('startip'), item.get('endip'))
    require(endpoints in (OLD, NEW), 'POD_ENDPOINTS_CHANGED')
    for command, kind in (('listSystemVms', 'systemvm'), ('listVirtualMachines', 'virtualmachine'), ('listRouters', 'router')):
        require(not rows(api, command, kind, zoneid=ZONE, listall='true'), 'SOURCE_ZONE_HAS_VMS')
    # This diagnostic refresh updates derived capacity counters. It is reported explicitly.
    capacities = rows(api, 'listCapacity', 'capacity', zoneid=ZONE, podid=POD, type=5, fetchlatest='true')
    require(len(capacities) == 1, 'PRIVATE_IP_CAPACITY_UNKNOWN')
    capacity = capacities[0]
    require(capacity.get('type') == 5 and capacity.get('podid') == POD and capacity.get('zoneid') == ZONE,
            'PRIVATE_IP_CAPACITY_SCOPE_CHANGED')
    require(type(capacity.get('capacityused')) is int and capacity['capacityused'] == 0, 'POD_HAS_ALLOCATED_IPS_OR_UNKNOWN')
    require(capacity.get('capacitytotal') == (253 if endpoints == OLD else 8), 'POD_CAPACITY_TOTAL_CHANGED')
    return endpoints


def execute(api, journal=None, apply=False):
    current = observe(api)
    result = {'schema': 1, 'target': '10.10.10.14', 'zoneEnabled': False,
              'derivedCapacityRefreshRequested': True, 'configurationUpdateRequested': apply,
              'currentStart': current[0], 'currentEnd': current[1], 'command': 'updatePodManagementNetworkIpRange',
              'parameters': PARAMS, 'status': 'PLAN_REVIEW_REQUIRED'}
    if not apply:
        return result
    require(journal is not None, 'PERSISTENT_JOURNAL_REQUIRED')
    operation = journal.data['operations'].get('pod-range')
    if operation:
        require(operation.get('params') == PARAMS, 'RANGE_INTENT_CHANGED')
    if current == NEW:
        require(operation is not None, 'UNJOURNALED_RANGE_CHANGE')
    else:
        require(operation is None, 'UNCERTAIN_RANGE_UPDATE_NO_REPLAY')
        operation = {'params': PARAMS, 'state': 'SUBMITTING'}
        journal.data['operations']['pod-range'] = operation
        journal.save()
        try:
            response = api('updatePodManagementNetworkIpRange', **PARAMS)
            job_id = identifier(response.get('jobid'))
            operation.update(state='ASYNC_SUBMITTED', job_id=job_id)
            journal.save()
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                status = api('queryAsyncJobResult', jobid=job_id).get('jobstatus')
                if status == 1:
                    break
                require(status == 0, 'NATIVE_RANGE_JOB_FAILED')
                time.sleep(1)
        except Exception:
            operation['state'] = 'SUBMISSION_UNCERTAIN'
            journal.save()
        # Exact re-list is authoritative after timeout; never repeat the submission.
        require(observe(api) == NEW, 'UNCERTAIN_RANGE_UPDATE_NO_REPLAY')
    operation['state'] = 'RECONCILED'
    journal.save()
    result.update(status='RANGE_RECONCILED_NOT_SYSTEMVM_READY', currentStart=NEW[0], currentEnd=NEW[1])
    return result
