#!/usr/bin/env python3
"""Read only the exact retained failed qualification's metadata and QCOW headers."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import struct
import subprocess
import xml.etree.ElementTree as ET

DOMAIN='e8b009d6-a1f5-45c3-8c99-ebd9c8ce023d'
PLAN='ddd70a78-d1dd-4ce1-a178-3216ab9fb60b'
FULL='58dfac24-aab8-42a0-adb8-b94202ed7680'
INCREMENTAL='6101efb8-a063-4e04-a945-dc4242767028'
ROOT=Path('/var/lib/libvirt/images')/('layersentry-drqc-'+PLAN)


def require(value):
    if not value:raise ValueError('READ_ONLY_BINDING_FAILED')


def regular(path,limit):
    require(path.resolve()==path)
    for ancestor in path.parents:
        info=ancestor.stat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid==0 and not info.st_mode&0o022)
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    info=os.fstat(fd)
    if not (stat.S_ISREG(info.st_mode) and info.st_nlink==1 and info.st_uid==0 and info.st_size<=limit):
        os.close(fd);raise ValueError('READ_ONLY_FILE_BINDING_FAILED')
    return fd,info


def qcow_header(path):
    fd,info=regular(path,11*1024**3)
    with os.fdopen(fd,'rb') as stream:
        header=stream.read(104)
        require(len(header)==104 and header[:4]==b'QFI\xfb')
        version=struct.unpack_from('>I',header,4)[0]
        offset,size=struct.unpack_from('>QI',header,8)
        require(version in (2,3) and size<=4096 and offset+size<=info.st_size)
        backing=None
        if size:
            require(104<=offset<=2*1024**2)
            stream.seek(offset);backing=stream.read(size).decode('utf-8')
        return {'file':str(path),'bytes':info.st_size,'mode':oct(stat.S_IMODE(info.st_mode)),
            'version':version,'backingOffset':offset,'backingSize':size,'backingFilename':backing,
            'clusterBits':struct.unpack_from('>I',header,20)[0],
            'virtualBytes':struct.unpack_from('>Q',header,24)[0],
            'cryptMethod':struct.unpack_from('>I',header,32)[0],
            'snapshots':struct.unpack_from('>I',header,60)[0],
            'incompatibleFeatures':struct.unpack_from('>Q',header,72)[0] if version==3 else 0}


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--target',required=True)
    args=parser.parse_args()
    require(args.target=='10.10.10.20' and os.geteuid()==0)
    require(subprocess.check_output(['hostname','-f'],text=True,timeout=10).strip()=='layersentry-dr-mgmt1')
    addresses=json.loads(subprocess.check_output(['ip','-j','-4','address','show'],timeout=10))
    require(any(a.get('local')==args.target for link in addresses for a in link.get('addr_info',[])))
    import libvirt
    connection=libvirt.openReadOnly('qemu:///system')
    try:
        domain=connection.lookupByUUIDString(DOMAIN)
        require(domain.UUIDString()==DOMAIN and domain.name()=='layersentry-cpuqc-'+DOMAIN)
        checkpoints=[]
        for checkpoint in domain.listAllCheckpoints(0):
            name=checkpoint.getName()
            require(name in {'lsdr-'+FULL,'lsdr-'+INCREMENTAL})
            xml=checkpoint.getXMLDesc(0)
            require(len(xml)<=65536 and '<!DOCTYPE' not in xml and '<!ENTITY' not in xml)
            row=ET.fromstring(xml)
            checkpoints.append({'name':name,'creationTime':row.findtext('creationTime'),
                'parent':row.findtext('parent/name'),'domainUuid':row.findtext('domain/uuid')})
        stats=domain.jobStats(0)
        work=Path('/var/lib/libvirt/images')/('layersentry-cpuqc-'+DOMAIN)
        ownership=work/'ownership.json'
        fd,owner_info=regular(ownership,65536)
        with os.fdopen(fd,'rb') as handle:owner_sha=hashlib.sha256(handle.read()).hexdigest()
        retirement=work/'retirement-intent.json'
        retirement_info={'exists':os.path.lexists(retirement)}
        if retirement_info['exists']:
            fd,info=regular(retirement,2*1024**2)
            with os.fdopen(fd,'rb') as handle:retirement_info['sha256']=hashlib.sha256(handle.read()).hexdigest()
        result={'schemaVersion':'1.0','target':args.target,'status':'COLLECTED','mutationPerformed':False,
            'captureRun':'34057792718','domainUuid':DOMAIN,'domainActive':domain.isActive(),
            'job':{key:value for key,value in stats.items() if key in ('type','operation','time_elapsed','disk_total','disk_processed','disk_remaining')},
            'checkpoints':checkpoints,'headers':[qcow_header(ROOT/'capture'/epoch/'vda.qcow2') for epoch in (FULL,INCREMENTAL)],
            'qemuParserInvoked':False,'checkpointMutationPerformed':False,
            'retirementIntent':retirement_info,'ownershipSha256':owner_sha,'domainPersistent':bool(domain.isPersistent())}
        print(json.dumps(result,sort_keys=True))
    finally:connection.close()


if __name__=='__main__':
    main()
