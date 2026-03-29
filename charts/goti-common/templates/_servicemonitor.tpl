{{- define "goti-common.servicemonitor" -}}
{{- $sm := .Values.serviceMonitor | default dict }}
{{- if $sm.enabled }}
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: {{ include "goti-common.fullname" . }}
  labels:
    {{- include "goti-common.labels" . | nindent 4 }}
    release: {{ .Values.serviceMonitor.release | default "kube-prometheus-stack-dev" }}
    {{- with .Values.serviceMonitor.additionalLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  selector:
    matchLabels:
      {{- include "goti-common.selectorLabels" . | nindent 6 }}
  namespaceSelector:
    matchNames:
      - {{ .Release.Namespace }}
  endpoints:
    - port: {{ .Values.serviceMonitor.port | default .Values.service.name | default "http" }}
      interval: {{ .Values.serviceMonitor.interval | default "30s" }}
      path: {{ .Values.serviceMonitor.path | default "/metrics" }}
      {{- with .Values.serviceMonitor.scrapeTimeout }}
      scrapeTimeout: {{ . }}
      {{- end }}
      {{- with .Values.serviceMonitor.metricRelabelings }}
      metricRelabelings:
        {{- toYaml . | nindent 8 }}
      {{- end }}
{{- end }}
{{- end }}
