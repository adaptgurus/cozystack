import base64
import subprocess
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


class LabRangeTests(unittest.TestCase):
    def receipts(self):
        return {name:(ROOT/'evidence'/('lab-pod-reviewed-'+name+'.json')).read_bytes() for name in controller.LAB_RECEIPTS}

    def test_real_receipts_and_exclusive_reservation_are_required(self):
        controller.verify_lab_receipts(self.receipts(),controller.LAB_RESERVATION)
        with self.assertRaisesRegex(GateError,'RESERVATION'):
            controller.verify_lab_receipts(self.receipts(),'general-production')
        tampered=self.receipts();tampered['capacity']+=b' '
        with self.assertRaisesRegex(GateError,'DIGEST'):
            controller.verify_lab_receipts(tampered,controller.LAB_RESERVATION)

    def test_lab_plan_preserves_unknown_and_blocks_overrides_or_pending_jobs(self):
        state={'override':'false','jobs':[]}
        def rows(api,cmd,kind,**params):
            if cmd=='listConfigurations':return [{'name':params['name'],'value':state['override']}]
            self.assertEqual(cmd,'listAsyncJobs');self.assertEqual(params,{'listall':'true'})
            return state['jobs']
        with patch.object(controller,'observe_scope',return_value=controller.OLD),patch.object(controller,'rows',side_effect=rows):
            result=controller.execute_lab(None,self.receipts(),controller.LAB_RESERVATION)
            self.assertEqual(result['capacityUsed'],'UNKNOWN_DISABLED_ZONE')
            self.assertFalse(result['configurationUpdateRequested'])
            state['override']='true'
            with self.assertRaisesRegex(GateError,'OVERRIDE'):
                controller.execute_lab(None,self.receipts(),controller.LAB_RESERVATION)
            state['override']='false';state['jobs']=[{'jobid':'unrelated'}]
            with self.assertRaisesRegex(GateError,'PENDING_NATIVE'):
                controller.execute_lab(None,self.receipts(),controller.LAB_RESERVATION)

    def test_lab_async_intent_reconciles_without_claiming_zero_or_replaying(self):
        with tempfile.TemporaryDirectory() as directory:
            os.chmod(directory,0o700)
            journal=Journal(directory,{'lab':True},'http://127.0.0.1:8080/client/api')
            state={'range':controller.OLD,'calls':0}
            def api(cmd,**params):
                if cmd=='updatePodManagementNetworkIpRange':
                    self.assertEqual(json.loads((Path(directory)/'journal.json').read_text())['operations']['pod-range']['mode'],'exclusive-disabled-dc-lab')
                    state['calls']+=1;state['range']=controller.NEW
                    return {'jobid':'9eebba10-0c37-42c9-8b56-3e39bc10145f'}
                self.assertEqual(cmd,'queryAsyncJobResult');return {'jobstatus':1}
            with patch.object(controller,'observe_lab',side_effect=lambda api,job=None:state['range']):
                result=controller.execute_lab(api,self.receipts(),controller.LAB_RESERVATION,journal,True)
                controller.execute_lab(api,self.receipts(),controller.LAB_RESERVATION,journal,True)
            self.assertEqual(state['calls'],1)
            self.assertEqual(result['capacityUsed'],'UNKNOWN_DISABLED_ZONE')
            self.assertIn('NOT_SYSTEMVM_READY',result['status'])
            journal.close()

    def test_default_path_still_rejects_hidden_capacity(self):
        with patch.object(controller,'observe_scope',return_value=controller.OLD),patch.object(controller,'rows',return_value=[]):
            with self.assertRaisesRegex(GateError,'PRIVATE_IP_CAPACITY_UNKNOWN'):
                controller.execute(None)

    def test_plan_loader_cannot_select_apply(self):
        spec=importlib.util.spec_from_file_location('pod_plan_loader',ROOT/'run-dc-pod-range-plan-stdin.py')
        loader=importlib.util.module_from_spec(spec);spec.loader.exec_module(loader)
        payload={'schema':1,'target':'10.10.10.14','mode':'Apply','sources':{},'proof':'','apiKey':'fixture','apiSecret':'fixture','labReceipts':{},'reservation':controller.LAB_RESERVATION}
        with self.assertRaisesRegex(ValueError,'INPUT_SCOPE'):
            loader.parse_payload(json.dumps(payload).encode())


@unittest.skipUnless(os.environ.get('POWERSHELL_TEST_BINARY'),'PowerShell execution required')
class PlanTransportTests(unittest.TestCase):
    def test_actual_legacy_plan_bundle_and_invalid_input_are_private(self):
        source=(ROOT/'invoke-dc-pod-range-plan-ssh.ps1').read_text()
        section=source[source.index('    $proof = '):source.index("    $state.status = 'SSH_OR_COLLECTOR_FAILED'")]
        pre="$ErrorActionPreference='Stop';$Mode='Plan';$state=@{};$known='fixture';$env:CLOUDSTACK_API_KEY='PRIVATE_TEST_KEY';$env:CLOUDSTACK_SECRET_KEY='PRIVATE_TEST_SECRET'\n"
        post="""
if(($sshArgs -join ' ') -match 'PRIVATE_TEST'){throw 'Secret in arguments'}
$payload=$envelope|ConvertFrom-Json
if($payload.labReceipts.PSObject.Properties.Name.Count -ne 3){throw 'Receipt bundle missing'}
$PSNativeCommandArgumentPassing='Legacy'
& python3 -c 'import base64,sys;print(base64.b64encode(sys.argv[1].encode()).decode())' $remote
"""
        with tempfile.NamedTemporaryFile('w',suffix='.ps1') as file:
            file.write(pre+section+post);file.flush()
            ps=subprocess.run([os.environ['POWERSHELL_TEST_BINARY'],'-NoProfile','-File',file.name],cwd=ROOT.parents[1],capture_output=True,text=True,timeout=20)
        self.assertEqual(ps.returncode,0,ps.stderr)
        command=base64.b64decode(ps.stdout.strip()).decode()
        process=subprocess.run(['bash','-c',command],input='{}',capture_output=True,text=True,timeout=10)
        self.assertEqual(process.returncode,1)
        self.assertEqual(json.loads(process.stdout)['status'],'PRIVATE_INPUT_OR_NETWORK_GATE')
        self.assertFalse(process.stderr)
