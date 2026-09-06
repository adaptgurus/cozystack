import contextlib,hashlib,importlib.util,io,json,os,pathlib,sys,tempfile,types,unittest
from unittest.mock import patch
SOURCE=pathlib.Path(__file__).with_name('stop-retained-dr-cpu-fixture.py')
spec=importlib.util.spec_from_file_location('stopfixture',SOURCE);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class Fixture(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
  self.path=pathlib.Path(self.tmp.name)/('layersentry-cpuqc-'+m.DOMAIN);self.path.mkdir()
  self.disk=self.path/'runtime.qcow2';self.disk.write_bytes(b'original disk')
  self.record={'domainUuid':m.DOMAIN,'domainName':self.path.name,'diskPath':str(self.disk),'networkInterfaces':0,'retainForDrQualification':True,'productionQualified':False}
  raw=json.dumps(self.record).encode();(self.path/'ownership.json').write_bytes(raw);(self.path/'ownership.json').chmod(0o600)
  self.cp=[types.SimpleNamespace(getName=lambda n=n:n,XMLDesc=lambda flags,n=n:'<domaincheckpoint><name>'+n+'</name></domaincheckpoint>') for n in sorted(m.CHECKPOINTS)]
  self.changed=0;self.closed=False;self.uuid=m.DOMAIN;self.job=0;self.persistent=False;self.nic=False
  self.dom=types.SimpleNamespace(UUIDString=lambda:self.uuid,name=lambda:self.path.name,isPersistent=lambda:self.persistent,jobStats=lambda f:{'type':self.job},listAllCheckpoints=lambda f:self.cp,XMLDesc=lambda f:'<domain><devices><disk device="disk"><source file="'+str(self.disk)+'"/></disk>'+('<interface/>' if self.nic else '')+'</devices></domain>',shutdown=self.shutdown)
  self.domains=[self.dom]
  self.conn=types.SimpleNamespace(listAllDomains=lambda f:self.domains,close=lambda:None)
  for p in [patch.object(m,'DIRECTORY',self.path),patch.object(m,'OWNERSHIP_SHA256',hashlib.sha256(raw).hexdigest()),patch.object(m.os,'geteuid',return_value=0),patch.object(m.subprocess,'check_output',return_value='layersentry-dr-mgmt1\n'),patch.dict(sys.modules,libvirt=types.SimpleNamespace(open=lambda uri:self.conn,VIR_DOMAIN_JOB_NONE=0))]:p.start();self.addCleanup(p.stop)
  # The fixture models target uid0; preserve all real filesystem fields except owner uid.
  original_stat=pathlib.Path.stat
  def stat_as_target(path,*args,**kwargs):
   value=original_stat(path,*args,**kwargs)
   if str(path).startswith(self.tmp.name):
    fields=list(value);fields[4]=0;return os.stat_result(fields)
   return value
  owner_patch=patch.object(pathlib.Path,'stat',stat_as_target);owner_patch.start();self.addCleanup(owner_patch.stop)
 def shutdown(self):
  self.assertTrue((self.path/'retirement-intent.json').is_file());self.changed+=1;self.domains=[]
 def runmain(self):
  with contextlib.redirect_stdout(io.StringIO()) as output:m.main()
  return json.loads(output.getvalue())
 def test_retains_definitions_before_stop_and_disk_after(self):
  result=self.runmain();self.assertEqual(self.changed,1);self.assertEqual(self.disk.read_bytes(),b'original disk');self.assertTrue(result['domainAbsent']);self.assertEqual(set(json.loads((self.path/'retirement-intent.json').read_text())['checkpoints']),m.CHECKPOINTS)
 def test_unknown_domain_refused(self):
  self.uuid='foreign'
  with self.assertRaises(ValueError):self.runmain()
  self.assertEqual(self.changed,0)
 def test_active_job_refused(self):
  self.job=1
  with self.assertRaises(ValueError):self.runmain()
  self.assertEqual(self.changed,0)
 def test_persistent_domain_refused(self):
  self.persistent=True
  with self.assertRaises(ValueError):self.runmain()
 def test_network_interface_refused(self):
  self.nic=True
  with self.assertRaises(ValueError):self.runmain()
 def test_conflicting_durable_intent_refused(self):
  (self.path/'retirement-intent.json').write_text('{}');(self.path/'retirement-intent.json').chmod(0o600)
  with self.assertRaises(ValueError):self.runmain()
  self.assertEqual(self.changed,0)
 def test_bad_owner_record_refused(self):
  (self.path/'ownership.json').write_text('{}')
  with self.assertRaises(ValueError):self.runmain()
 def test_already_absent_does_not_replay(self):
  self.domains=[];result=self.runmain();self.assertFalse(result['mutationPerformed']);self.assertEqual(self.changed,0)
if __name__=='__main__':unittest.main(verbosity=2)
