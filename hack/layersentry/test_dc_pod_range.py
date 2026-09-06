import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).parent
for name,file in [('dc_native_storage_registration','register-dc-native-storage.py'),('dc_pod_range','dc-pod-range.py')]:
    spec=importlib.util.spec_from_file_location(name,ROOT/file)
    module=importlib.util.module_from_spec(spec);sys.modules[name]=module;spec.loader.exec_module(module)
controller=sys.modules['dc_pod_range']
from dr_recovery_acceptance import GateError,Journal

class RangeTests(unittest.TestCase):
    def test_actual_native_observation_uses_exact_range_role_and_fresh_zero_count(self):
        pod={'gateway':'10.10.10.1','netmask':'255.255.255.0','ipranges':[{'startip':controller.OLD[0],'endip':controller.OLD[1],'forsystemvms':'0','vlanid':'vlan://untagged'}]}
        count={'type':5,'podid':controller.POD,'zoneid':controller.ZONE,'capacityused':0,'capacitytotal':253}
        def rows(api,cmd,kind,**params):
            if cmd=='listCapacity':
                self.assertEqual(params,{'zoneid':controller.ZONE,'podid':controller.POD,'type':5,'fetchlatest':'true'})
                return [count]
            return []
        with patch.object(controller,'preflight'),patch.object(controller,'exact',return_value=pod),patch.object(controller,'rows',side_effect=rows):
            self.assertEqual(controller.observe(None),controller.OLD)
            for bad in (1,None,'0'):
                count['capacityused']=bad
                with self.assertRaisesRegex(GateError,'ALLOCATED'):
                    controller.observe(None)
            count['capacityused']=0
            pod['ipranges'][0]['vlanid']='vlan://123'
            with self.assertRaisesRegex(GateError,'ROLE_OR_VLAN'):
                controller.observe(None)

    def test_durable_async_submit_then_exact_postcondition_and_repeat_reconcile(self):
        with tempfile.TemporaryDirectory() as directory:
            os.chmod(directory,0o700);journal=Journal(directory,{'fixed':'range'},'http://127.0.0.1:8080/client/api')
            state={'range':controller.OLD,'calls':[]}
            def api(cmd,**params):
                state['calls'].append(cmd)
                if cmd=='updatePodManagementNetworkIpRange':
                    self.assertEqual(json.loads((Path(directory)/'journal.json').read_text())['operations']['pod-range']['state'],'SUBMITTING')
                    self.assertEqual(params,controller.PARAMS)
                    state['range']=controller.NEW
                    return {'jobid':'9eebba10-0c37-42c9-8b56-3e39bc10145f'}
                self.assertEqual(cmd,'queryAsyncJobResult');return {'jobstatus':1}
            with patch.object(controller,'observe',side_effect=lambda _:state['range']):
                result=controller.execute(api,journal,True)
                self.assertEqual(result['currentEnd'],'10.10.10.9')
                controller.execute(api,journal,True)
            self.assertEqual(state['calls'].count('updatePodManagementNetworkIpRange'),1)
            journal.close()

    def test_ambiguous_update_without_effect_is_not_replayed_after_reload(self):
        with tempfile.TemporaryDirectory() as directory:
            os.chmod(directory,0o700);journal=Journal(directory,{'fixed':'range'},'http://127.0.0.1:8080/client/api')
            with patch.object(controller,'observe',return_value=controller.OLD),patch.object(controller,'time'):
                with self.assertRaisesRegex(GateError,'NO_REPLAY'):
                    controller.execute(lambda *a,**kw:(_ for _ in ()).throw(TimeoutError()),journal,True)
            journal.close();journal=Journal(directory,{'fixed':'range'},'http://127.0.0.1:8080/client/api')
            with patch.object(controller,'observe',return_value=controller.OLD):
                with self.assertRaisesRegex(GateError,'NO_REPLAY'):
                    controller.execute(lambda *a,**kw:self.fail('Mutation replayed'),journal,True)
            journal.close()

    def test_plan_never_submits_range_update(self):
        with patch.object(controller,'observe',return_value=controller.OLD):
            result=controller.execute(lambda *a,**kw:self.fail('Plan submitted native update'))
        self.assertFalse(result['configurationUpdateRequested'])
        self.assertTrue(result['derivedCapacityRefreshRequested'])
