import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import yaml

ROOT = Path(__file__).parents[2]
PWSH = os.environ.get('POWERSHELL_TEST_BINARY')
STUB = r'''
function Import-Module { param($Name,$ErrorAction,[switch]$Force) }
function Get-DcGuestJournalObservation { @{status='OBSERVED';prepareIntent=$false;connectIntent=$false} }
function Get-Service { param($ErrorAction) [pscustomobject]@{Name='DHCPServer';Status='Running'} }
function Get-DhcpServerv4Scope { param($ComputerName,$ErrorAction) [pscustomobject]@{ScopeId='10.10.10.0';StartRange='10.10.10.2';EndRange='10.10.10.100';SubnetMask='255.255.255.0';State='Active'} }
function Get-DhcpServerv4ExclusionRange { param($ComputerName,$ScopeId,$ErrorAction) if($env:FAIL_DHCP -eq 'true'){throw 'PRIVATE_ERROR_SENTINEL'}; [pscustomobject]@{StartRange='10.10.10.14';EndRange='10.10.10.20'} }
function Get-DhcpServerv4Reservation { param($ComputerName,$ScopeId,$ErrorAction) [pscustomobject]@{IPAddress='10.10.10.14';ClientId='00155d00390a';Type='Both';Name='PRIVATE_HOST_SENTINEL'} }
function Get-DhcpServerv4Lease { param($ComputerName,$ScopeId,[switch]$AllLeases,$ErrorAction) [pscustomobject]@{IPAddress='10.10.10.14';ClientId='00155d00390a';AddressState='Active';HostName='PRIVATE_HOST_SENTINEL'} }
function Get-NetIPInterface { param($AddressFamily,$ErrorAction) }
function Get-NetNeighbor { param($AddressFamily,$ErrorAction) }
function Get-VMSwitch { }
function Get-NetAdapter { }
function Get-NetIPAddress { param($AddressFamily) }
function Get-NetRoute { param($AddressFamily) }
function Get-NetNat { param($ErrorAction) }
function Get-NetNatStaticMapping { param($ErrorAction) }
function Get-VMNetworkAdapter { param([switch]$All) }
'''

@unittest.skipUnless(PWSH, 'PowerShell execution required')
class InventoryTests(unittest.TestCase):
    def test_actual_workflow_projects_dhcp_and_preserves_unknown_failure(self):
        workflow = yaml.safe_load((ROOT / '.github/workflows/layersentry-hyperv-network-inventory.yml').read_text())
        source = workflow['jobs']['inventory']['steps'][1]['run']
        for failure in ('false', 'true'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                script = Path(directory) / 'fixture.ps1'
                script.write_text(STUB + '\n' + source)
                env = dict(os.environ, COMPUTERNAME='TESTSER', RUNNER_TEMP=directory, GITHUB_RUN_ID='fixture', FAIL_DHCP=failure)
                result = subprocess.run([PWSH, '-NoProfile', '-File', str(script)], env=env, capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stderr)
                data = json.loads((Path(directory) / 'network-inventory-fixture/network-inventory.json').read_text(encoding='utf-8-sig'))
                self.assertEqual(data['dhcp']['status'], 'DHCP_CONFIGURATION_UNAVAILABLE' if failure == 'true' else 'OBSERVED')
                self.assertFalse(data['mutationPerformed'])
                self.assertFalse(data['dcGuestNetworkJournal']['prepareIntent'])
                self.assertNotIn('PRIVATE_', json.dumps(data))
                if failure == 'false':
                    self.assertEqual(data['dhcp']['scopes'][0]['end'], '10.10.10.100')
                    self.assertEqual(data['dhcp']['reservations'][0]['address'], '10.10.10.14')
