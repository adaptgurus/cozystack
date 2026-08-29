{{- define "linstor-gateway.selectorLabels" -}}
app.kubernetes.io/name: linstor-gateway
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "linstor-gateway.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{ include "linstor-gateway.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: storage-gateway
app.kubernetes.io/part-of: layersentry-storage
{{- end }}
