#!/usr/bin/env python3
"""Stop one completed qualification guest, preserving all disks and journals."""
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import time
import xml.etree.ElementTree as ET

DOMAIN='e8b009d6-a1f5-45c3-8c99-ebd9c8ce023d'
DIRECTORY=Path('/var/lib/libvirt/images')/('layersentry-cpuqc-'+DOMAIN)
OWNERSHIP_SHA256='a9c05cb68c225ed0a8a5d61da6307a8f61aa196081629f8a0fb9f305e987e989'
CHECKPOINTS={'lsdr-58dfac24-aab8-42a0-adb8-b94202ed7680','lsdr-6101efb8-a063-4e04-a945-dc4242767028'}


def require(value):
    if not value:raise ValueError('EXACT_FIXTURE_RETIREMENT_GATE')


def retain_intent(domain, xml):
    """Preserve transient definitions durably before the domain can disappear."""
    intent={'domainUuid':DOMAIN,'ownershipSha256':OWNERSHIP_SHA256,'domainXml':xml,
            'checkpoints':{item.getName():item.XMLDesc(0) for item in domain.listAllCheckpoints(0)}}
    require(set(intent['checkpoints'])==CHECKPOINTS)
    path=DIRECTORY/'retirement-intent.json'
    raw=(json.dumps(intent,sort_keys=True)+'\n').encode()
    try:fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    except FileExistsError:
        info=path.lstat()
        require(stat.S_ISREG(info.st_mode) and info.st_uid==0 and info.st_nlink==1 and not info.st_mode&0o077)
        require(path.read_bytes()==raw)
    else:
        with os.fdopen(fd,'wb') as output:output.write(raw);output.flush();os.fsync(output.fileno())
        parent=os.open(DIRECTORY,os.O_RDONLY|os.O_DIRECTORY)
        try:os.fsync(parent)
        finally:os.close(parent)


def main():
    require(os.geteuid()==0)
    require(subprocess.check_output(['hostname','-f'],text=True,timeout=10).strip()=='layersentry-dr-mgmt1')
    require(DIRECTORY.resolve()==DIRECTORY)
    ownership=DIRECTORY/'ownership.json'
    require(not ownership.is_symlink() and ownership.stat().st_uid==0 and not ownership.stat().st_mode&0o077)
    raw=ownership.read_bytes()
    require(hashlib.sha256(raw).hexdigest()==OWNERSHIP_SHA256)
    record=json.loads(raw)
    require(record['domainUuid']==DOMAIN and record['domainName']==DIRECTORY.name
            and record['diskPath']==str(DIRECTORY/'runtime.qcow2') and record['networkInterfaces']==0
            and record['retainForDrQualification'] is True and record['productionQualified'] is False)
    disk=DIRECTORY/'runtime.qcow2';before=disk.lstat()
    require(stat.S_ISREG(before.st_mode) and before.st_nlink==1)
    import libvirt
    connection=libvirt.open('qemu:///system')
    changed=False
    try:
        domains=connection.listAllDomains(0)
        require(all(item.UUIDString()==DOMAIN for item in domains))
        if domains:
            domain=domains[0]
            require(domain.name()==DIRECTORY.name and not domain.isPersistent())
            require(domain.jobStats(0).get('type')==libvirt.VIR_DOMAIN_JOB_NONE)
            require({item.getName() for item in domain.listAllCheckpoints(0)}==CHECKPOINTS)
            xml=domain.XMLDesc(0)
            require(len(xml)<2*1024**2 and '<!DOCTYPE' not in xml and '<!ENTITY' not in xml)
            tree=ET.fromstring(xml)
            require(not tree.findall('./devices/interface'))
            disks=[item for item in tree.findall('./devices/disk') if item.get('device')=='disk' and item.find('readonly') is None]
            require(len(disks)==1 and disks[0].find('source').get('file')==record['diskPath'])
            retain_intent(domain,xml)
            domain.shutdown();changed=True
            deadline=time.monotonic()+60
            while any(item.UUIDString()==DOMAIN for item in connection.listAllDomains(0)) and time.monotonic()<deadline:
                time.sleep(2)
            domains=connection.listAllDomains(0)
            if domains:
                require(len(domains)==1 and domains[0].UUIDString()==DOMAIN and not domains[0].isPersistent())
                require(domains[0].jobStats(0).get('type')==libvirt.VIR_DOMAIN_JOB_NONE)
                domains[0].destroy()
            require(not connection.listAllDomains(0))
        after=disk.lstat()
        require((before.st_dev,before.st_ino)==(after.st_dev,after.st_ino) and stat.S_ISREG(after.st_mode))
        require(hashlib.sha256(ownership.read_bytes()).hexdigest()==OWNERSHIP_SHA256)
        print(json.dumps({'schemaVersion':'1.0','target':'10.10.10.20','status':'RETIRED',
            'domainUuid':DOMAIN,'domainAbsent':True,'sourceFilesPreserved':True,
            'catalogAndJournalsPreserved':True,'mutationPerformed':changed,'ownershipSha256':OWNERSHIP_SHA256}))
    finally:connection.close()


if __name__=='__main__':main()
