# LayerSentry TESTSER dashboard tenant / Plan schema evidence

Generated (UTC): 2026-08-29T08:05:01.9668647Z
Workflow commit: fc1ee207bd3b7923dcac7bd5a31296791f1ab2ec
Safety: read-only Kubernetes inspection. No Secret contents, credentials, disk mutation, StoragePool creation, apply, patch, or delete operations are included.

## Kubernetes nodes
```text
NAME          STATUS   ROLES           AGE   VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE          KERNEL-VERSION   CONTAINER-RUNTIME
talos-2b1ae   Ready    control-plane   21h   v1.34.3   10.10.10.13   <none>        Talos (v1.13.6)   6.18.38-talos    containerd://2.2.5
talos-5284c   Ready    control-plane   21h   v1.34.3   10.10.10.12   <none>        Talos (v1.13.6)   6.18.38-talos    containerd://2.2.5
talos-e8576   Ready    control-plane   21h   v1.34.3   10.10.10.11   <none>        Talos (v1.13.6)   6.18.38-talos    containerd://2.2.5
exit=0
```

## Tenant / Plan / Backup API resources
```text

tenants                                                                                        
apps.cozystack.io/v1alpha1                 true         Tenant                              
create,delete,get,list,patch,update,watch                    
foundationdbbackups                  fdbbackup                                                 
apps.foundationdb.org/v1beta2              true         FoundationDBBackup                  
delete,deletecollection,get,list,patch,create,update,watch   
virtualmachinebackups                vmbackup,vmbackups                                        
backup.kubevirt.io/v1alpha1                true         VirtualMachineBackup                
delete,deletecollection,get,list,patch,create,update,watch   all
virtualmachinebackuptrackers         vmbackuptracker,vmbackuptrackers                          
backup.kubevirt.io/v1alpha1                true         VirtualMachineBackupTracker         
delete,deletecollection,get,list,patch,create,update,watch   all
backupclasses                                                                                  
backups.cozystack.io/v1alpha1              false        BackupClass                         
delete,deletecollection,get,list,patch,create,update,watch   
backupjobs                                                                                     
backups.cozystack.io/v1alpha1              true         BackupJob                           
delete,deletecollection,get,list,patch,create,update,watch   
backups                                                                                        
backups.cozystack.io/v1alpha1              true         Backup                              
delete,deletecollection,get,list,patch,create,update,watch   
plans                                                                                          
backups.cozystack.io/v1alpha1              true         Plan                                
delete,deletecollection,get,list,patch,create,update,watch   
restorejobs                                                                                    
backups.cozystack.io/v1alpha1              true         RestoreJob                          
delete,deletecollection,get,list,patch,create,update,watch   
kamajicontrolplanes                  ktcp                                                      
controlplane.cluster.x-k8s.io/v1alpha1     true         KamajiControlPlane                  
delete,deletecollection,get,list,patch,create,update,watch   cluster-api,kamaji
kamajicontrolplanetemplates          ktcpt                                                     
controlplane.cluster.x-k8s.io/v1alpha1     true         KamajiControlPlaneTemplate          
delete,deletecollection,get,list,patch,create,update,watch   cluster-api,kamaji
tenantmodules                                                                                  
core.cozystack.io/v1alpha1                 true         TenantModule                        get,list,watch             
                                  
tenantnamespaces                                                                               
core.cozystack.io/v1alpha1                 false        TenantNamespace                     get,list,watch             
                                  
tenantsecrets                                                                                  
core.cozystack.io/v1alpha1                 true         TenantSecret                        
create,delete,get,list,patch,update,watch                    
tenantgateways                       tgw                                                       
gateway.cozystack.io/v1alpha1              true         TenantGateway                       
delete,deletecollection,get,list,patch,create,update,watch   
backups                              bmdb                                                      
k8s.mariadb.com/v1alpha1                   true         Backup                              
delete,deletecollection,get,list,patch,create,update,watch   
physicalbackups                      pbmdb                                                     
k8s.mariadb.com/v1alpha1                   true         PhysicalBackup                      
delete,deletecollection,get,list,patch,create,update,watch   
tenantcontrolplanes                  tcp                                                       
kamaji.clastix.io/v1alpha1                 true         TenantControlPlane                  
delete,deletecollection,get,list,patch,create,update,watch   kamaji
opensearchtenants                    opensearchtenant                                          opensearch.opster.io/v1 
                   true         OpensearchTenant                    
delete,deletecollection,get,list,patch,create,update,watch   
controlplaneproviders                cacpp                                                     
operator.cluster.x-k8s.io/v1alpha2         true         ControlPlaneProvider                
delete,deletecollection,get,list,patch,create,update,watch   
backups                                                                                        postgresql.cnpg.io/v1   
                   true         Backup                              
delete,deletecollection,get,list,patch,create,update,watch   
scheduledbackups                                                                               postgresql.cnpg.io/v1   
                   true         ScheduledBackup                     
delete,deletecollection,get,list,patch,create,update,watch   
perconaservermongodbbackups          psmdb-backup                                              psmdb.percona.com/v1    
                   true         PerconaServerMongoDBBackup          
delete,deletecollection,get,list,patch,create,update,watch   
altinities                                                                                     
strategy.backups.cozystack.io/v1alpha1     false        Altinity                            
delete,deletecollection,get,list,patch,create,update,watch   
cnpgs                                                                                          
strategy.backups.cozystack.io/v1alpha1     false        CNPG                                
delete,deletecollection,get,list,patch,create,update,watch   
etcds                                                                                          
strategy.backups.cozystack.io/v1alpha1     false        Etcd                                
delete,deletecollection,get,list,patch,create,update,watch   
foundationdbs                                                                                  
strategy.backups.cozystack.io/v1alpha1     false        FoundationDB                        
delete,deletecollection,get,list,patch,create,update,watch   
jobs                                                                                           
strategy.backups.cozystack.io/v1alpha1     false        Job                                 
delete,deletecollection,get,list,patch,create,update,watch   
mariadbs                                                                                       
strategy.backups.cozystack.io/v1alpha1     false        MariaDB                             
delete,deletecollection,get,list,patch,create,update,watch   
veleroes                                                                                       
strategy.backups.cozystack.io/v1alpha1     false        Velero                              
delete,deletecollection,get,list,patch,create,update,watch   
backuprepositories                                                                             velero.io/v1            
                   true         BackupRepository                    
delete,deletecollection,get,list,patch,create,update,watch   
backups                                                                                        velero.io/v1            
                   true         Backup                              
delete,deletecollection,get,list,patch,create,update,watch   
backupstoragelocations               bsl                                                       velero.io/v1            
                   true         BackupStorageLocation               
delete,deletecollection,get,list,patch,create,update,watch   
deletebackuprequests                                                                           velero.io/v1            
                   true         DeleteBackupRequest                 
delete,deletecollection,get,list,patch,create,update,watch   
podvolumebackups                                                                               velero.io/v1            
                   true         PodVolumeBackup                     
delete,deletecollection,get,list,patch,create,update,watch
exit=0
```

## Cozystack APIService health
```text

v1alpha1.apps.cozystack.io                   cozy-system/cozystack-api                 True        20h
v1alpha1.backups.cozystack.io                Local                                     True        20h
v1alpha1.blockstor.cozystack.io              Local                                     True        4h26m
v1alpha1.core.cozystack.io                   cozy-system/cozystack-api                 True        20h
v1alpha1.cozystack.io                        Local                                     True        20h
v1alpha1.gateway.cozystack.io                Local                                     True        20h
v1alpha1.infrastructure.cozystack.io         Local                                     True        19h
v1alpha1.sdn.cozystack.io                    cozy-system/cozystack-api                 True        20h
v1alpha1.strategy.backups.cozystack.io       Local                                     True        20h
v1alpha1.virtualization.cozystack.io         Local                                     True        19h
v1alpha2.etcd-operator.cozystack.io          Local                                     True        20h
exit=0
```

## backups.cozystack.io APIService
```text
apiVersion: apiregistration.k8s.io/v1
kind: APIService
metadata:
  creationTimestamp: "2026-08-28T11:13:53Z"
  labels:
    kube-aggregator.kubernetes.io/automanaged: "true"
  name: v1alpha1.backups.cozystack.io
  resourceVersion: "7994"
  uid: 1bee77f5-4077-449f-af0f-164b583be41a
spec:
  group: backups.cozystack.io
  groupPriorityMinimum: 1000
  version: v1alpha1
  versionPriority: 100
status:
  conditions:
  - lastTransitionTime: "2026-08-28T11:13:53Z"
    message: Local APIServices are always available
    reason: Local
    status: "True"
    type: Available
exit=0
```

## TenantNamespaces aggregated API
```text
apiVersion: v1
items:
- apiVersion: core.cozystack.io/v1alpha1
  kind: TenantNamespace
  metadata:
    annotations:
      meta.helm.sh/release-name: cozystack-basics
      meta.helm.sh/release-namespace: cozy-system
      ovn.kubernetes.io/cidr: 10.244.0.0/16
      ovn.kubernetes.io/exclude_ips: 10.244.0.1
      ovn.kubernetes.io/logical_switch: ovn-default
    creationTimestamp: "2026-08-28T11:23:39Z"
    labels:
      app.kubernetes.io/managed-by: Helm
      helm.toolkit.fluxcd.io/name: cozystack-basics
      helm.toolkit.fluxcd.io/namespace: cozy-system
      internal.cozystack.io/flux-shard: shard0
      kubernetes.io/metadata.name: tenant-root
      namespace.cozystack.io/host: 10-10-10-200.nip.io
      platform.cozystack.io/no-delete: "true"
    name: tenant-root
    resourceVersion: "23393"
    uid: 346391cb-6435-41d9-8307-ed309a720ec5
kind: List
metadata:
  resourceVersion: ""
exit=0
```

## tenant-root Namespace
```text
apiVersion: v1
kind: Namespace
metadata:
  annotations:
    meta.helm.sh/release-name: cozystack-basics
    meta.helm.sh/release-namespace: cozy-system
    ovn.kubernetes.io/cidr: 10.244.0.0/16
    ovn.kubernetes.io/exclude_ips: 10.244.0.1
    ovn.kubernetes.io/logical_switch: ovn-default
  creationTimestamp: "2026-08-28T11:23:39Z"
  labels:
    app.kubernetes.io/managed-by: Helm
    helm.toolkit.fluxcd.io/name: cozystack-basics
    helm.toolkit.fluxcd.io/namespace: cozy-system
    internal.cozystack.io/flux-shard: shard0
    kubernetes.io/metadata.name: tenant-root
    namespace.cozystack.io/host: 10-10-10-200.nip.io
    platform.cozystack.io/no-delete: "true"
  name: tenant-root
  resourceVersion: "23393"
  uid: 346391cb-6435-41d9-8307-ed309a720ec5
spec:
  finalizers:
  - kubernetes
status:
  phase: Active
exit=0
```

## Existing generated Tenant objects
```text
apiVersion: v1
items:
- apiVersion: apps.cozystack.io/v1alpha1
  kind: Tenant
  metadata:
    creationTimestamp: "2026-08-28T11:23:40Z"
    name: root
    namespace: tenant-root
    resourceVersion: "1767920"
    uid: 1c145705-53d1-42cd-aaa9-57ca05b38931
  spec:
    etcd: true
    host: ""
    ingress: true
    monitoring: true
    resourceQuotas: {}
    schedulingClass: ""
    seaweedfs: true
  status:
    conditions:
    - lastTransitionTime: "2026-08-29T03:42:30Z"
      message: Helm upgrade succeeded for release tenant-root/tenant-root.v4 with
        chart tenant@0.0.0+3d3d1a503f60
      reason: UpgradeSucceeded
      status: "True"
      type: Ready
    - lastTransitionTime: "2026-08-29T03:42:30Z"
      message: Helm upgrade succeeded for release tenant-root/tenant-root.v4 with
        chart tenant@0.0.0+3d3d1a503f60
      reason: UpgradeSucceeded
      status: "True"
      type: Released
    externalIPsCount: 1
    namespace: tenant-root
    version: 0.0.0+3d3d1a503f60
kind: List
metadata:
  resourceVersion: ""
exit=0
```

## Tenant HelmReleases
```text

cozy-system                      tenant-rd                      20h     True    Helm upgrade succeeded for release 
cozy-system/tenant-rd.v2 with chart tenant-rd@0.0.0+38e1f5923c89
tenant-root                      bucket-cozy-backups            20h     True    Helm upgrade succeeded for release 
tenant-root/bucket-cozy-backups.v3 with chart bucket@0.0.0+beeaec6d9398
tenant-root                      bucket-cozy-backups-system     20h     True    Helm upgrade succeeded for release 
tenant-root/bucket-cozy-backups-system.v72 with chart cozy-bucket@0.0.0+c9d367eabd35
tenant-root                      etcd                           19h     True    Helm upgrade succeeded for release 
tenant-root/etcd.v2 with chart etcd@0.0.0+c4afe1b73177
tenant-root                      info                           20h     True    Helm upgrade succeeded for release 
tenant-root/info.v2 with chart info@0.0.0+95fae54d85cc
tenant-root                      ingress                        19h     True    Helm upgrade succeeded for release 
tenant-root/ingress.v2 with chart ingress@0.0.0+6f1e489019fb
tenant-root                      ingress-nginx-system           19h     True    Helm upgrade succeeded for release 
tenant-root/ingress-nginx-system.v2 with chart cozy-ingress-nginx@0.0.0+ec715ffe436e
tenant-root                      monitoring                     19h     True    Helm upgrade succeeded for release 
tenant-root/monitoring.v2 with chart monitoring@0.0.0+c1633117480c
tenant-root                      monitoring-system              19h     True    Helm upgrade succeeded for release 
tenant-root/monitoring-system.v2 with chart monitoring@0.0.0+5c246dfd1ad8
tenant-root                      seaweedfs                      14h     True    Helm upgrade succeeded for release 
tenant-root/seaweedfs.v2 with chart seaweedfs@0.0.0+734381953512
tenant-root                      seaweedfs-db                   14h     True    Helm upgrade succeeded for release 
tenant-root/seaweedfs-db.v2 with chart cozy-seaweedfs-db@0.0.0+7c59024ed46e
tenant-root                      seaweedfs-system               14h     True    Helm upgrade succeeded for release 
tenant-root/seaweedfs-system.v2 with chart cozy-seaweedfs@0.0.0+400651d563a7
tenant-root                      tenant-root                    20h     True    Helm upgrade succeeded for release 
tenant-root/tenant-root.v4 with chart tenant@0.0.0+3d3d1a503f60
exit=0
```

## Tenant ApplicationDefinition candidates
```text

tenant                20h
exit=0
```

## Tenant ApplicationDefinition YAML
```text
apiVersion: cozystack.io/v1alpha1
kind: ApplicationDefinition
metadata:
  annotations:
    meta.helm.sh/release-name: tenant-rd
    meta.helm.sh/release-namespace: cozy-system
    release.cozystack.io/helm-install-timeout: 15m
  creationTimestamp: "2026-08-28T11:23:26Z"
  generation: 1
  labels:
    app.kubernetes.io/managed-by: Helm
    helm.toolkit.fluxcd.io/name: tenant-rd
    helm.toolkit.fluxcd.io/namespace: cozy-system
  name: tenant
  resourceVersion: "22789"
  uid: d6139d11-0c21-4f0f-ae16-357d5fe74731
spec:
  application:
    kind: Tenant
    openAPISchema: '{"title":"Chart Values","type":"object","properties":{"host":{"description":"The
      hostname used to access tenant services (defaults to using the tenant name as
      a subdomain for its parent tenant host).","type":"string","default":""},"etcd":{"description":"Deploy
      own Etcd cluster.","type":"boolean","default":false},"monitoring":{"description":"Deploy
      own Monitoring Stack.","type":"boolean","default":false},"ingress":{"description":"Deploy
      own Ingress Controller.","type":"boolean","default":false},"gateway":{"description":"Deploy
      own Gateway API Gateway (backed by Cilium Gateway API controller). When unset
      (the default), the chart auto-enables the Gateway for tenants whose apex is
      derived from the parent (i.e. `host` is empty), and leaves it off for tenants
      with a custom non-derived apex. Set to `true` or `false` explicitly to override
      that auto-behaviour. Note: leave the key absent (do not write `gateway: null`)
      — the chart distinguishes \"unset\" via missing-key, not via null value, to
      satisfy the JSON schema generated from this comment.","type":"boolean"},"seaweedfs":{"description":"Deploy
      own SeaweedFS.","type":"boolean","default":false},"schedulingClass":{"description":"The
      name of a SchedulingClass CR to apply scheduling constraints for this tenant''s
      workloads.","type":"string","default":""},"resourceQuotas":{"description":"Define
      resource quotas for the tenant.","type":"object","default":{},"additionalProperties":{"pattern":"^(\\+|-)?(([0-9]+(\\.[0-9]*)?)|(\\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\\+|-)?(([0-9]+(\\.[0-9]*)?)|(\\.[0-9]+))))?$","anyOf":[{"type":"integer"},{"type":"string"}],"x-kubernetes-int-or-string":true}}}}'
    plural: tenants
    singular: tenant
  dashboard:
    category: Administration
    description: Separated tenant namespace
    icon: PHN2ZyB3aWR0aD0iMTQ0IiBoZWlnaHQ9IjE0NCIgdmlld0JveD0iMCAwIDE0NCAxNDQiIGZpbGw9Im5vbmUiIHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2ZyI+CjxyZWN0IHdpZHRoPSIxNDQiIGhlaWdodD0iMTQ0IiByeD0iMjQiIGZpbGw9InVybCgjcGFpbnQwX2xpbmVhcl82ODdfMzQwMykiLz4KPGcgY2xpcC1wYXRoPSJ1cmwoI2NsaXAwXzY4N18zNDAzKSI+CjxwYXRoIGQ9Ik03MiAyOUM2Ni4zOTI2IDI5IDYxLjAxNDggMzEuMjM4OCA1Ny4wNDk3IDM1LjIyNEM1My4wODQ3IDM5LjIwOTEgNTAuODU3MSA0NC42MTQxIDUwLjg1NzEgNTAuMjVDNTAuODU3MSA1NS44ODU5IDUzLjA4NDcgNjEuMjkwOSA1Ny4wNDk3IDY1LjI3NkM2MS4wMTQ4IDY5LjI2MTIgNjYuMzkyNiA3MS41IDcyIDcxLjVDNzcuNjA3NCA3MS41IDgyLjk4NTIgNjkuMjYxMiA4Ni45NTAzIDY1LjI3NkM5MC45MTUzIDYxLjI5MDkgOTMuMTQyOSA1NS44ODU5IDkzLjE0MjkgNTAuMjVDOTMuMTQyOSA0NC42MTQxIDkwLjkxNTMgMzkuMjA5MSA4Ni45NTAzIDM1LjIyNEM4Mi45ODUyIDMxLjIzODggNzcuNjA3NCAyOSA3MiAyOVpNNjAuOTgyNiA4My4zMDM3QzYwLjQ1NCA4Mi41ODk4IDU5LjU5NTEgODIuMTkxNCA1OC43MTk2IDgyLjI3NDRDNDUuMzg5NyA4My43MzU0IDM1IDk1LjEwNzQgMzUgMTA4LjkwM0MzNSAxMTEuNzI2IDM3LjI3OTUgMTE0IDQwLjA3MSAxMTRIMTAzLjkyOUMxMDYuNzM3IDExNCAxMDkgMTExLjcwOSAxMDkgMTA4LjkwM0MxMDkgOTUuMTA3NCA5OC42MTAzIDgzLjc1MiA4NS4yNjM4IDgyLjI5MUM4NC4zODg0IDgyLjE5MTQgODMuNTI5NSA4Mi42MDY0IDgzLjAwMDkgODMuMzIwM0w3NC4wOTc4IDk1LjI0MDJDNzMuMDQwNiA5Ni42NTE0IDcwLjkyNjMgOTYuNjUxNCA2OS44NjkyIDk1LjI0MDJMNjAuOTY2MSA4My4zMjAzTDYwLjk4MjYgODMuMzAzN1oiIGZpbGw9ImJsYWNrIi8+CjwvZz4KPGRlZnM+CjxsaW5lYXJHcmFkaWVudCBpZD0icGFpbnQwX2xpbmVhcl82ODdfMzQwMyIgeDE9IjcyIiB5MT0iMTQ0IiB4Mj0iLTEuMjgxN2UtMDUiIHkyPSI0IiBncmFkaWVudFVuaXRzPSJ1c2VyU3BhY2VPblVzZSI+CjxzdG9wIHN0b3AtY29sb3I9IiNDMEQ2RkYiLz4KPHN0b3Agb2Zmc2V0PSIwLjMiIHN0b3AtY29sb3I9IiNDNERBRkYiLz4KPHN0b3Agb2Zmc2V0PSIwLjY1IiBzdG9wLWNvbG9yPSIjRDNFOUZGIi8+CjxzdG9wIG9mZnNldD0iMSIgc3RvcC1jb2xvcj0iI0U5RkZGRiIvPgo8L2xpbmVhckdyYWRpZW50Pgo8Y2xpcFBhdGggaWQ9ImNsaXAwXzY4N18zNDAzIj4KPHJlY3Qgd2lkdGg9Ijc0IiBoZWlnaHQ9Ijg1IiBmaWxsPSJ3aGl0ZSIgdHJhbnNmb3JtPSJ0cmFuc2xhdGUoMzUgMjkpIi8+CjwvY2xpcFBhdGg+CjwvZGVmcz4KPC9zdmc+Cg==
    keysOrder:
    - - apiVersion
    - - appVersion
    - - kind
    - - metadata
    - - metadata
      - name
    - - spec
      - host
    - - spec
      - etcd
    - - spec
      - monitoring
    - - spec
      - ingress
    - - spec
      - seaweedfs
    - - spec
      - schedulingClass
    - - spec
      - resourceQuotas
    plural: Tenants
    singular: Tenant
  release:
    chartRef:
      kind: ExternalArtifact
      name: cozystack-tenant-application-default-tenant
      namespace: cozy-system
    labels:
      sharding.fluxcd.io/key: tenants
    prefix: tenant-
  secrets:
    exclude: []
    include: []
exit=0
```

## Tenant ExternalArtifact source
```text
apiVersion: source.toolkit.fluxcd.io/v1
kind: ExternalArtifact
metadata:
  creationTimestamp: "2026-08-28T11:10:27Z"
  generation: 1
  labels:
    app.kubernetes.io/managed-by: source-watcher
    source.extensions.fluxcd.io/generator: 24622f07-b39b-438a-b4d6-cb90f778f7df
  name: cozystack-tenant-application-default-tenant
  namespace: cozy-system
  resourceVersion: "560295"
  uid: af4c9a9e-4f55-4173-9635-ca637ad76e78
spec:
  sourceRef:
    apiVersion: source.extensions.fluxcd.io/v1beta1
    kind: ArtifactGenerator
    name: cozystack.tenant-application
    namespace: cozy-system
status:
  artifact:
    digest: sha256:3d3d1a503f603480918fcdc6b345f0e51790f241c1034aa4692c07f6ae675d0f
    lastUpdateTime: "2026-08-28T17:41:48Z"
    path: externalartifact/cozy-system/cozystack-tenant-application-default-tenant/2183407662.tar.gz
    revision: latest@sha256:3d3d1a503f603480918fcdc6b345f0e51790f241c1034aa4692c07f6ae675d0f
    size: 23086
    url: http://flux.cozy-fluxcd.svc/externalartifact/cozy-system/cozystack-tenant-application-default-tenant/2183407662.tar.gz
  conditions:
  - lastTransitionTime: "2026-08-28T17:41:48Z"
    message: Artifact is ready
    observedGeneration: 1
    reason: Succeeded
    status: "True"
    type: Ready
exit=0
```

## Plan-related CRDs
```text

altinities.strategy.backups.cozystack.io                       2026-08-28T11:24:22Z
backupclasses.backups.cozystack.io                             2026-08-28T11:13:53Z
backupjobs.backups.cozystack.io                                2026-08-28T11:13:53Z
backuprepositories.velero.io                                   2026-08-28T11:21:33Z
backups.backups.cozystack.io                                   2026-08-28T11:13:53Z
backups.k8s.mariadb.com                                        2026-08-28T11:16:27Z
backups.postgresql.cnpg.io                                     2026-08-28T11:16:30Z
backups.velero.io                                              2026-08-28T11:21:33Z
backupstoragelocations.velero.io                               2026-08-28T11:21:33Z
cnpgs.strategy.backups.cozystack.io                            2026-08-28T11:24:22Z
controlplaneproviders.operator.cluster.x-k8s.io                2026-08-28T11:17:00Z
deletebackuprequests.velero.io                                 2026-08-28T11:21:34Z
etcds.strategy.backups.cozystack.io                            2026-08-28T11:24:22Z
foundationdbbackups.apps.foundationdb.org                      2026-08-28T11:16:35Z
foundationdbs.strategy.backups.cozystack.io                    2026-08-28T11:24:22Z
jobs.strategy.backups.cozystack.io                             2026-08-28T11:24:22Z
kamajicontrolplanes.controlplane.cluster.x-k8s.io              2026-08-28T11:20:26Z
kamajicontrolplanetemplates.controlplane.cluster.x-k8s.io      2026-08-28T11:20:27Z
mariadbs.strategy.backups.cozystack.io                         2026-08-28T11:24:22Z
perconaservermongodbbackups.psmdb.percona.com                  2026-08-28T11:18:05Z
physicalbackups.k8s.mariadb.com                                2026-08-28T11:16:27Z
plans.backups.cozystack.io                                     2026-08-28T11:13:53Z
podvolumebackups.velero.io                                     2026-08-28T11:21:35Z
restorejobs.backups.cozystack.io                               2026-08-28T11:13:53Z
scheduledbackups.postgresql.cnpg.io                            2026-08-28T11:16:30Z
tenantcontrolplanes.kamaji.clastix.io                          2026-08-28T11:18:51Z
veleroes.strategy.backups.cozystack.io                         2026-08-28T11:24:22Z
virtualmachinebackups.backup.kubevirt.io                       2026-08-28T11:15:51Z
virtualmachinebackuptrackers.backup.kubevirt.io                2026-08-28T11:15:51Z
exit=0
```

## Plan / Backup ApplicationDefinition candidates
```text
<no output>
exit=0
```

## Plan ApplicationDefinition YAML
```text
<no output>
exit=1
```

## Plan CRD served/storage/schema summary
```text
ERROR: Cannot convert the JSON string because a dictionary that was converted from the string contains the duplicated keys 'proxyURL' and 'proxyUrl'.
```

## Plan API discovery and objects
```text
--- plans.backups.cozystack.io ---
kubectl.exe : No resources found
At C:\actions-runner\_work\_temp\abc8340a-ad23-4f5c-b791-e9ac84279327.ps1:74 char:5
+     & $kubectl get $resource -A -o wide 2>&1
+     ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    + CategoryInfo          : NotSpecified: (No resources found:String) [], RemoteException
    + FullyQualifiedErrorId : NativeCommandError
 
--- kamajicontrolplanes.controlplane.cluster.x-k8s.io ---
kubectl.exe : No resources found
At C:\actions-runner\_work\_temp\abc8340a-ad23-4f5c-b791-e9ac84279327.ps1:74 char:5
+     & $kubectl get $resource -A -o wide 2>&1
+     ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    + CategoryInfo          : NotSpecified: (No resources found:String) [], RemoteException
    + FullyQualifiedErrorId : NativeCommandError
 
--- kamajicontrolplanetemplates.controlplane.cluster.x-k8s.io ---
kubectl.exe : No resources found
At C:\actions-runner\_work\_temp\abc8340a-ad23-4f5c-b791-e9ac84279327.ps1:74 char:5
+     & $kubectl get $resource -A -o wide 2>&1
+     ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    + CategoryInfo          : NotSpecified: (No resources found:String) [], RemoteException
    + FullyQualifiedErrorId : NativeCommandError
 
--- tenantcontrolplanes.kamaji.clastix.io ---
kubectl.exe : No resources found
At C:\actions-runner\_work\_temp\abc8340a-ad23-4f5c-b791-e9ac84279327.ps1:74 char:5
+     & $kubectl get $resource -A -o wide 2>&1
+     ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    + CategoryInfo          : NotSpecified: (No resources found:String) [], RemoteException
    + FullyQualifiedErrorId : NativeCommandError
 
--- controlplaneproviders.operator.cluster.x-k8s.io ---
NAMESPACE          NAME     INSTALLEDVERSION      READY
cozy-cluster-api   kamaji   v0.19.0-cozystack.0   True
exit=0
```

## OpenAPI v3 Cozystack / Backup schema summary
```text
apis/apps.cozystack.io url=/openapi/v3/apis/apps.cozystack.io?hash=BC9013FA6E906517EB1E4DC381DC4C9CBD408A9122A5F41A7924B684314CBCBD1F687E28680A40BFAAB0C884F3500F60451D6E4E85D03AA36F5C75199990B502 exit=0 bytes=4319 containsPlan=False
apis/apps.cozystack.io/v1alpha1 url=/openapi/v3/apis/apps.cozystack.io/v1alpha1?hash=E456341092D88F2EC927DDB3E19EA611A3EF6BA0FB4F9F006ED495C58E10F326E75633E401FDD1859D5BF969C2AEBAC51297451AC516C21D2440E266B68DD100 exit=0 bytes=1864569 containsPlan=True
apis/backup.kubevirt.io/v1alpha1 url=/openapi/v3/apis/backup.kubevirt.io/v1alpha1?hash=E09B5D0B8A93249C5AABE361616157308136132A5FAF6798894A6F80C1CEEC0D4852BC807AC066C601E4A97D87AC7877E915512D4423066843DDE3F83C33302C exit=0 bytes=130422 containsPlan=False
apis/backups.cozystack.io/v1alpha1 url=/openapi/v3/apis/backups.cozystack.io/v1alpha1?hash=1B11C71E3B7F8EB762081758176B39915E04A5E630CA5FE6A3BAEC77D081F05F50AC9BBF47FCBCDEFC88739CE4DBBA77BBB5B897315E17FF73E964948AEF4B48 exit=0 bytes=268021 containsPlan=True
apis/blockstor.cozystack.io/v1alpha1 url=/openapi/v3/apis/blockstor.cozystack.io/v1alpha1?hash=33DFC4E39C539AF750050FCA2A914477146F7DE8BFF35122F7F6A91E17EBFED0839910D70B5749060BDCD53D6D387A784CC32A14662748A8019E6F834AF2D828 exit=0 bytes=334407 containsPlan=False
apis/core.cozystack.io url=/openapi/v3/apis/core.cozystack.io?hash=6BAC9A502600D870199E657141E96B8CE9CAAF3D90BBF3BE95BB34B0FAC01731E6839ECB2E5C000DA1E86A2F6E944220F1559225F0DF08CADEAC9E54E309CDA6 exit=0 bytes=4319 containsPlan=False
apis/core.cozystack.io/v1alpha1 url=/openapi/v3/apis/core.cozystack.io/v1alpha1?hash=AC8FBFB2DDF540F9FE13D2CDFB0DBCA0A6062AB7C6BE1A5C69D507C796D5246F40061641AE7E29FF7CEE1F128D0BB16EB2DD445325D5E70A5E4D1F1DF31F1C56 exit=0 bytes=206348 containsPlan=False
apis/cozystack.io/v1alpha1 url=/openapi/v3/apis/cozystack.io/v1alpha1?hash=114B8B256E4346E555E800C1C0B92D89A87223F53E6CD2C623F51EE34DEAB00A839D553A41131DA104CDD7DE4F37EE2F0585DC401A187E865E60CB94AB4A1995 exit=0 bytes=327971 containsPlan=False
apis/etcd-operator.cozystack.io/v1alpha2 url=/openapi/v3/apis/etcd-operator.cozystack.io/v1alpha2?hash=D351EB282AC2F180EE52A4477B0E181FCB7D74194F3252C719A8C8CD68BD897DDE91ACB2753BDC0D719B0152D555073CCC258E9DD866F667514EF81AB776178F exit=0 bytes=377746 containsPlan=True
apis/gateway.cozystack.io/v1alpha1 url=/openapi/v3/apis/gateway.cozystack.io/v1alpha1?hash=412E73259F480CEAEE267FFCD1C2543EE0F6202AC9DC3C7F8E84CAEF99BCCCA137612CF25F361200F1792933BA18AF3E57A7F11ED0C9B787A658111FC84D0A51 exit=0 bytes=85927 containsPlan=False
apis/infrastructure.cozystack.io/v1alpha1 url=/openapi/v3/apis/infrastructure.cozystack.io/v1alpha1?hash=603F1D652EFE3F46BB62F4EC8A55C4823CC01F5B269D200BF0014F66D5D2502317EEBEBC733EAE13725CAFBB283E0EE38480499BAC1F3A5FB69FE652A10891BE exit=0 bytes=73113 containsPlan=False
apis/sdn.cozystack.io url=/openapi/v3/apis/sdn.cozystack.io?hash=ED4E67794874939294FCD52A86B449F8EF1621D79A8F893194CCBFB23B6B40203F32A004B01BD73E3EB413FBA55078B5653D1020A3C7CB0AC49815CCBDD415B3 exit=0 bytes=4316 containsPlan=False
apis/sdn.cozystack.io/v1alpha1 url=/openapi/v3/apis/sdn.cozystack.io/v1alpha1?hash=62CE2BD529C0AFD26AF3B9D4440B03B8218E85CA1C4FD38A6282EFF13E235651EE15934FAACC3C3B027D21D644DB0BF4D611E63C490F6623468DF9597A839124 exit=0 bytes=92491 containsPlan=False
apis/strategy.backups.cozystack.io/v1alpha1 url=/openapi/v3/apis/strategy.backups.cozystack.io/v1alpha1?hash=81F11FAC36EB2E755D8908DB636FA1E26AC1C49D1AA20AFA489D1680C81CCDBC4D3074AA39490508C557BAFF5360765175E164D7B5968F7A47D9D7E3355371A1 exit=0 bytes=1347342 containsPlan=True
apis/virtualization.cozystack.io/v1alpha1 url=/openapi/v3/apis/virtualization.cozystack.io/v1alpha1?hash=68C48ADC461FD1DC5DECCC5FD7E50FD27C5C69BE9670068521B6B915AA17B13CF531B0374A5C3FC6DD838AFD8A33E7975701908D9DB9F938795ED9FB6CA76657 exit=0 bytes=79548 containsPlan=False
exit=0
```

## apps.cozystack.io discovery
```text
{"kind":"APIResourceList","apiVersion":"v1","groupVersion":"apps.cozystack.io/v1alpha1","resources":[{"name":"buckets","singularName":"bucket","namespaced":true,"group":"apps.cozystack.io","version":"v1alpha1","kind":"Bucket","verbs":["create","delete","get","list","patch","update","watch"]},{"name":"clickhouses","singularName":"clickhouse","namespaced":true,"group":"apps.cozystack.io","version":"v1alpha1","kind":"ClickHouse","verbs":["create","delete","get","list","patch","update","watch"]},{"name":"etcds","singularName":"etcd","namespaced":true,"group":"apps.cozystack.io","version":"v1alpha1","kind":"Etcd","verbs":["create","delete","get","list","patch","update","watch"]},{"name":"foundationdbs","singularName":"foundationdb","namespaced":true,"group":"apps.cozystack.io","version":"v1alpha1","kind":"FoundationDB","verbs":["create","delete","get","list","patch","update","watch"]},{"name":"harbors","singularName":"harbor","namespaced":true,"group":"apps.cozystack.io","version":"v1alpha1","kind":"Harbor","verbs":["create","delete","get","list","patch","update","watch"]},{"name":"httpcaches","singularName":"httpcache","namespaced":true,"group":"apps.cozystack.io","version":"v1alpha1","kind":"HTTPCache","verbs":["create","delete","get","list","patch","update","watch"]},{"name":"infos","singularName":"info","namespaced":true,"group":"apps.cozystack.io","version":"v1alpha1","kind":"Info","verbs":["create","delete","get","list","patch","update","watch"]},{"name":"ingresses","singularName":"ingress","namespaced":true,"group":"apps.cozystack.io","version":"v1alpha1","kind":"Ingress","verbs":["create","delete","get","list","patch","update","watch"]},{"name":"kafkas","singularName":"kafka","namespaced":true,"group":"apps.cozystack.io","version":"v1alpha1","kind":"Kafka","verbs":["create","delete","get","list","patch","update","watch"]},{"name":"kuberneteses","singularName":"kubernetes","namespaced":true,"group":"apps.cozystack.io","version":"v1alpha1","kind":"Kubernetes","verbs":["create","delete","get","list","patch","update","watch"]},{"name":"mariadbs","singularName":"mariadb","namespaced":true,"group":"apps.cozystack.io","version":"v1alpha1","kind":"MariaDB","verbs":["create","delete","get","list","patch","update","watch"]},{"name":"mongodbs","singularName":"mongodb","namespaced":true,"group":"apps.cozystack.io","version":"v1alpha1","kind":"MongoDB","verbs":["create","delete","get","list","patch","update","watch"]},{"name":"monitorings","singularName":"monitoring","namespaced":true,"group":"apps.cozystack.io","version":"v1alpha1","kind":"Monitoring","verbs":["create","delete","get","list","patch","update","watch"]},{"name":"natses","singularName":"nats","namespaced":true,"group":"apps.cozystack.io","version":"v1alpha1","kind":"NATS","verbs":["create","delete","get","list","patch","update","watch"]},{"name":"openbaos","singularName":"openbao","namespaced":true,"group":"apps.cozystack.io","version":"v1alpha1","kind":"OpenBAO","verbs":["create","delete","get","list","patch","update","watch"]},{"name":"opensearches","singularName":"opensearch","namespaced":true,"group":"apps.cozystack.io","version":"v1alpha1","kind":"OpenSearch","verbs":["create","delete","get","list","patch","update","watch"]},{"name":"postgreses","singularName":"postgres","namespaced":true,"group":"apps.cozystack.io","version":"v1alpha1","kind":"Postgres","verbs":["create","delete","get","list","patch","update","watch"]},{"name":"qdrants","singularName":"qdrant","namespaced":true,"group":"apps.cozystack.io","version":"v1alpha1","kind":"Qdrant","verbs":["create","delete","get","list","patch","update","watch"]},{"name":"rabbitmqs","singularName":"rabbitmq","namespaced":true,"group":"apps.cozystack.io","version":"v1alpha1","kind":"RabbitMQ","verbs":["create","delete","get","list","patch","update","watch"]},{"name":"redises","singularName":"redis","namespaced":true,"group":"apps.cozystack.io","version":"v1alpha1","kind":"Redis","verbs":["create","delete","get","list","patch","update","watch"]},{"name":"seaweedfses","singularName":"seaweedfs","namespaced":true,"group":"apps.cozystack.io","version":"v1alpha1","kind":"SeaweedFS","verbs":["create","delete","get","list","patch","update","watch"]},{"name":"tcpbalancers","singularName":"tcpbalancer","namespaced":true,"group":"apps.cozystack.io","version":"v1alpha1","kind":"TCPBalancer","verbs":["create","delete","get","list","patch","update","watch"]},{"name":"tenants","singularName":"tenant","namespaced":true,"group":"apps.cozystack.io","version":"v1alpha1","kind":"Tenant","verbs":["create","delete","get","list","patch","update","watch"]},{"name":"virtualprivateclouds","singularName":"virtualprivatecloud","namespaced":true,"group":"apps.cozystack.io","version":"v1alpha1","kind":"VirtualPrivateCloud","verbs":["create","delete","get","list","patch","update","watch"]},{"name":"vmdisks","singularName":"vmdisk","namespaced":true,"group":"apps.cozystack.io","version":"v1alpha1","kind":"VMDisk","verbs":["create","delete","get","list","patch","update","watch"]},{"name":"vminstances","singularName":"vminstance","namespaced":true,"group":"apps.cozystack.io","version":"v1alpha1","kind":"VMInstance","verbs":["create","delete","get","list","patch","update","watch"]},{"name":"vmnetworks","singularName":"vmnetwork","namespaced":true,"group":"apps.cozystack.io","version":"v1alpha1","kind":"VMNetwork","verbs":["create","delete","get","list","patch","update","watch"]},{"name":"vmtemplates","singularName":"vmtemplate","namespaced":true,"group":"apps.cozystack.io","version":"v1alpha1","kind":"VMTemplate","verbs":["create","delete","get","list","patch","update","watch"]},{"name":"vpns","singularName":"vpn","namespaced":true,"group":"apps.cozystack.io","version":"v1alpha1","kind":"VPN","verbs":["create","delete","get","list","patch","update","watch"]}]}
exit=0
```

## backups.cozystack.io discovery
```text
{"kind":"APIResourceList","apiVersion":"v1","groupVersion":"backups.cozystack.io/v1alpha1","resources":[{"name":"restorejobs","singularName":"restorejob","namespaced":true,"kind":"RestoreJob","verbs":["delete","deletecollection","get","list","patch","create","update","watch"],"storageVersionHash":"QFMjUXUJlps="},{"name":"restorejobs/status","singularName":"","namespaced":true,"kind":"RestoreJob","verbs":["get","patch","update"]},{"name":"backups","singularName":"backup","namespaced":true,"kind":"Backup","verbs":["delete","deletecollection","get","list","patch","create","update","watch"],"storageVersionHash":"KPbJ3BpC2r8="},{"name":"plans","singularName":"plan","namespaced":true,"kind":"Plan","verbs":["delete","deletecollection","get","list","patch","create","update","watch"],"storageVersionHash":"42tG4PThawE="},{"name":"plans/status","singularName":"","namespaced":true,"kind":"Plan","verbs":["get","patch","update"]},{"name":"backupjobs","singularName":"backupjob","namespaced":true,"kind":"BackupJob","verbs":["delete","deletecollection","get","list","patch","create","update","watch"],"storageVersionHash":"01uBGpUGYnA="},{"name":"backupjobs/status","singularName":"","namespaced":true,"kind":"BackupJob","verbs":["get","patch","update"]},{"name":"backupclasses","singularName":"backupclass","namespaced":false,"kind":"BackupClass","verbs":["delete","deletecollection","get","list","patch","create","update","watch"],"storageVersionHash":"XV8xyicBHgk="},{"name":"backupclasses/status","singularName":"","namespaced":false,"kind":"BackupClass","verbs":["get","patch","update"]}]}
exit=0
```

## Dashboard / Cozystack API / Backup pods
```text

cozy-backup-controller           backup-controller-77896f55f9-pzfck                                1/1     Running     
0               20h     10.244.0.19    talos-2b1ae   <none>           <none>
cozy-backup-controller           backup-controller-77896f55f9-zr4s4                                1/1     Running     
0               20h     10.244.0.20    talos-5284c   <none>           <none>
cozy-backup-controller           backupstrategy-controller-69b988775b-hfmc5                        1/1     Running     
0               14h     10.244.1.6     talos-e8576   <none>           <none>
cozy-backup-controller           backupstrategy-controller-69b988775b-lbjfb                        1/1     Running     
0               14h     10.244.1.5     talos-5284c   <none>           <none>
cozy-dashboard                   cozy-dashboard-console-6cff96cc6d-vgjqq                           1/1     Running     
0               14h     10.244.1.2     talos-e8576   <none>           <none>
cozy-dashboard                   incloud-web-gatekeeper-d97dc6b87-rb5jf                            1/1     Running     
0               4h26m   10.244.1.44    talos-2b1ae   <none>           <none>
cozy-grafana-operator            grafana-dashboards-549b46477c-fcd68                               1/1     Running     
0               20h     10.244.0.8     talos-2b1ae   <none>           <none>
cozy-system                      cozystack-api-6868d56d75-bg2pp                                    1/1     Running     
0               14h     10.244.1.0     talos-2b1ae   <none>           <none>
cozy-system                      cozystack-api-6868d56d75-wzvlr                                    1/1     Running     
0               14h     10.244.0.255   talos-e8576   <none>           <none>
tenant-root                      bucket-cozy-backups-ui-5c48f669c9-ktgxs                           1/1     Running     
0               20h     10.244.0.130   talos-2b1ae   <none>           <none>
exit=0
```

## Dashboard / API services and endpoints
```text
kubectl.exe : Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice
At C:\actions-runner\_work\_temp\abc8340a-ad23-4f5c-b791-e9ac84279327.ps1:100 char:56
+ ... ices and endpoints' { & $kubectl get svc,endpoints -A -o wide | Selec ...
+                           ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    + CategoryInfo          : NotSpecified: (Warning: v1 End...1 EndpointSlice:String) [], RemoteException
    + FullyQualifiedErrorId : NativeCommandError
 

cozy-dashboard                   service/cozy-dashboard-console                                     ClusterIP      
10.96.132.112   <none>                                             8080/TCP                      20h     
app.kubernetes.io/instance=cozy-dashboard,app.kubernetes.io/name=console
cozy-dashboard                   service/incloud-web-gatekeeper                                     ClusterIP      
10.96.181.130   <none>                                             8000/TCP                      20h     
app.kubernetes.io/instance=incloud-web,app.kubernetes.io/name=gatekeeper
cozy-grafana-operator            service/grafana-dashboards                                         ClusterIP      
10.96.146.63    <none>                                             80/TCP                        20h     
app.kubernetes.io/instance=grafana-operator,app.kubernetes.io/name=grafana-dashboards
cozy-system                      service/cozystack-api                                              ClusterIP      
10.96.239.99    <none>                                             443/TCP                       20h     
app=cozystack-api
tenant-root                      service/bucket-cozy-backups-ui                                     ClusterIP      
10.96.82.211    <none>                                             8080/TCP                      20h     
app=bucket-cozy-backups-ui
cozy-dashboard                   endpoints/cozy-dashboard-console                                     10.244.1.2:8080  
                                                     20h
cozy-dashboard                   endpoints/incloud-web-gatekeeper                                     10.244.1.44:8000 
                                                     20h
cozy-grafana-operator            endpoints/grafana-dashboards                                         10.244.0.8:8080  
                                                     20h
cozy-system                      endpoints/cozystack-api                                              
10.244.0.255:443,10.244.1.0:443                                       20h
tenant-root                      endpoints/bucket-cozy-backups-ui                                     
10.244.0.130:8080                                                     20h
exit=0
```

## Non-running/non-completed pods
```text
blockstor-system                 blockstor-satellite-cfdjj                                         0/1   Pending     0               4h26m
blockstor-system                 blockstor-satellite-dqr24                                         0/1   Pending     0               4h26m
blockstor-system                 blockstor-satellite-xvpb6                                         0/1   Pending     0               4h26m
exit=0
```

## HelmReleases not Ready
```text
NONE
exit=0
```

## Packages not Ready
```text
NONE
exit=0
```

## StorageClasses
```text
NAME              PROVISIONER              RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
local (default)   linstor.csi.linbit.com   Delete          WaitForFirstConsumer   true                   19h
replicated        linstor.csi.linbit.com   Delete          Immediate              true                   19h
exit=0
```

## Classic LINSTOR nodes
```text
╭───────────────────────────────────────────────────────────╮
│ Node        │ NodeType  │ Addresses              │ State  │
╞═══════════════════════════════════════════════════════════╡
│ talos-2b1ae │ SATELLITE │ 10.10.10.13:3367 (SSL) │ [1;32mOnline[0m │
│ talos-5284c │ SATELLITE │ 10.10.10.12:3367 (SSL) │ [1;32mOnline[0m │
│ talos-e8576 │ SATELLITE │ 10.10.10.11:3367 (SSL) │ [1;32mOnline[0m │
╰───────────────────────────────────────────────────────────╯
exit=0
```

## Classic LINSTOR storage pools
```text
╭───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╮
│ StoragePool          │ Node        │ Driver   │ PoolName │ FreeCapacity │ TotalCapacity │ CanSnapshots │ State │ SharedName                       │
╞═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╡
│ DfltDisklessStorPool │ talos-2b1ae │ DISKLESS │          │              │               │ False        │ [1;32mOk   [0m │ talos-2b1ae;DfltDisklessStorPool │
│ DfltDisklessStorPool │ talos-5284c │ DISKLESS │          │              │               │ False        │ [1;32mOk   [0m │ talos-5284c;DfltDisklessStorPool │
│ DfltDisklessStorPool │ talos-e8576 │ DISKLESS │          │              │               │ False        │ [1;32mOk   [0m │ talos-e8576;DfltDisklessStorPool │
│ data                 │ talos-2b1ae │ ZFS      │ data     │   164.79 GiB │       298 GiB │ True         │ [1;32mOk   [0m │ talos-2b1ae;data                 │
│ data                 │ talos-5284c │ ZFS      │ data     │   227.79 GiB │       298 GiB │ True         │ [1;32mOk   [0m │ talos-5284c;data                 │
│ data                 │ talos-e8576 │ ZFS      │ data     │   158.70 GiB │       298 GiB │ True         │ [1;32mOk   [0m │ talos-e8576;data                 │
╰───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯
exit=0
```

## Blockstor StoragePool safety boundary
```text
QUERY_UNAVAILABLE exit=1
exit=1
```

