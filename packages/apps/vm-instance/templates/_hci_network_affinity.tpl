{{/*
Merge verified NetworkFabric placement constraints with the existing Windows
node-placement policy. Every managed VMNetwork NAD carries a capability-label
annotation generated from fabric/network/bridge/VLAN/MTU. NetworkFabric publishes
that label only on nodes that passed live Talos capability verification.
*/}}
{{- define "virtual-machine.hciNodeAffinity" -}}
{{- $capabilities := dict -}}
{{- $networks := .Values.networks | default .Values.subnets -}}
{{- range $net := $networks -}}
  {{- if $net.name -}}
    {{- $nad := lookup "k8s.cni.cncf.io/v1" "NetworkAttachmentDefinition" $.Release.Namespace $net.name -}}
    {{- if $nad -}}
      {{- $annotations := $nad.metadata.annotations | default (dict) -}}
      {{- $capability := index $annotations "vm-network.cozystack.io/capability-label" | default "" -}}
      {{- if $capability -}}
        {{- $_ := set $capabilities $capability true -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{- $dedicatedWindows := false -}}
{{- if .Values._cluster.scheduling -}}
  {{- $dedicatedWindows = eq (get .Values._cluster.scheduling "dedicatedNodesForWindowsVMs") "true" -}}
{{- end -}}
{{- $isWindows := hasPrefix "windows" (toString .Values.instanceProfile) -}}
{{- $windowsRequired := and $dedicatedWindows $isWindows -}}
{{- $windowsPreferred := and $dedicatedWindows (not $isWindows) -}}
{{- $hasRequired := or $windowsRequired (gt (len $capabilities) 0) -}}
{{- if or $hasRequired $windowsPreferred }}
affinity:
  nodeAffinity:
    {{- if $hasRequired }}
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
      - matchExpressions:
        {{- range $key := keys $capabilities | sortAlpha }}
        - key: {{ $key | quote }}
          operator: Exists
        {{- end }}
        {{- if $windowsRequired }}
        - key: scheduling.cozystack.io/vm-windows
          operator: In
          values:
          - "true"
        {{- end }}
    {{- end }}
    {{- if $windowsPreferred }}
    preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      preference:
        matchExpressions:
        - key: scheduling.cozystack.io/vm-windows
          operator: NotIn
          values:
          - "true"
    {{- end }}
{{- end -}}
{{- end -}}
