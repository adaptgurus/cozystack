"""Run the workflow's actual PowerShell collector against an offline API stub.

Requires PyYAML and pwsh (or POWERSHELL pointing at a PowerShell executable).
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / '.github/workflows/layersentry-cloudstack-r0-api-inventory.yml'
PWSH = os.environ.get('POWERSHELL') or shutil.which('pwsh')
STUB = r'''
function Invoke-RestMethod {
  param($Uri, $Method, $TimeoutSec, $MaximumRedirection, $ErrorAction)
  if ($Method -ne 'Get' -or $MaximumRedirection -ne 0) { throw 'Unsafe HTTP options' }
  $command = [regex]::Match($Uri, '[?&]command=([^&]+)').Groups[1].Value
  if ($env:STUB_FAILURE -eq 'true' -and $command -eq 'listBackups') { throw 'Mock failure' }
  $collections = @{
    listCapabilities='capability'; listManagementServers='managementserver';
    listNetworks='network'; listTemplates='template'; listBackupProviders='providers';
    listBackups='backup'; listZones='zone'; listPods='pod'; listClusters='cluster';
    listHosts='host'; listStoragePools='storagepool'; listImageStores='imagestore';
    listBackupRepositories='backuprepository'; listBackupOfferings='backupoffering';
    listVirtualMachines='virtualmachine'; listAsyncJobs='asyncjobs'; listConfigurations='configuration'
  }
  if (-not $collections.ContainsKey($command)) { throw 'Unexpected API' }
  $item = @{ id='fixture-id'; name='fixture'; cloudstackversion='4.22.1.1'; password='SECRET_SENTINEL'; userdata='SECRET_SENTINEL'; url='SECRET_SENTINEL' }
  $count = if ($env:STUB_TRUNCATE -eq 'true' -and $command -eq 'listZones') { 10 } else { 1 }
  $payload = @{ count=$count }
  $payload[$collections[$command]] = @($item)
  $response = @{}
  $response[$command.ToLowerInvariant() + 'response'] = $payload
  return ($response | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
}
'''


@unittest.skipUnless(PWSH, 'PowerShell required for offline workflow execution')
class InventoryTests(unittest.TestCase):
    def collect(self, **overrides):
        script = yaml.safe_load(WORKFLOW.read_text())['jobs']['inventory']['steps'][0]['run']
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, RUNNER_TEMP=tmp, TARGET_PROFILE='dc',
                       CLOUDSTACK_API_ENDPOINT='http://10.10.10.14:8080/client/api',
                       CLOUDSTACK_API_KEY='fixture-key', CLOUDSTACK_SECRET_KEY='fixture-secret',
                       GITHUB_RUN_ID='offline', GITHUB_REPOSITORY='fixture/repo', GITHUB_SHA='fixture')
            env.update(overrides)
            path = Path(tmp) / 'collector.ps1'
            path.write_text(STUB + '\n' + script)
            result = subprocess.run([PWSH, '-NoProfile', '-File', str(path)],
                                    env=env, capture_output=True, text=True, timeout=30)
            evidence = Path(tmp) / 'layersentry-cloudstack-r0-api-inventory/inventory.json'
            data = json.loads(evidence.read_text(encoding='utf-8-sig')) if evidence.exists() else None
            return result, data

    def test_complete_inventory_projects_safe_fields(self):
        result, data = self.collect()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(data['InventoryComplete'])
        for name in ('ManagementServers', 'Networks', 'Templates', 'BackupProviders', 'Backups'):
            self.assertTrue(data[name], name)
        self.assertNotIn('SECRET_SENTINEL', json.dumps(data))
        self.assertNotIn('fixture-secret', result.stdout + result.stderr)

    def test_wrong_profile_endpoint_rejected(self):
        result, data = self.collect(TARGET_PROFILE='dr')
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(data)

    def test_dr_profile_endpoint(self):
        result, data = self.collect(TARGET_PROFILE='dr',
                                   CLOUDSTACK_API_ENDPOINT='http://10.10.10.20:8080/client/api')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(data['TargetProfile'], 'dr')

    def test_endpoint_query_rejected(self):
        result, data = self.collect(CLOUDSTACK_API_ENDPOINT='http://10.10.10.14:8080/client/api?token=untrusted')
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(data)

    def test_missing_credentials_rejected(self):
        result, data = self.collect(CLOUDSTACK_API_KEY='')
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(data)

    def test_truncated_inventory_fails_with_evidence(self):
        result, data = self.collect(STUB_TRUNCATE='true')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(data['InventoryComplete'])
        self.assertTrue(data['CollectionObservations']['zone']['Truncated'])

    def test_optional_api_failure_is_not_empty_success(self):
        result, data = self.collect(STUB_FAILURE='true')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(data['InventoryComplete'])
        self.assertEqual(data['BackupApiObservations']['listBackups']['Status'], 'FAILED')


if __name__ == '__main__':
    unittest.main()
