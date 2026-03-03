{{- define "goti-common.serviceaccount" -}}
{{- if .Values.serviceAccount.create }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ default (include "goti-common.fullname" .) .Values.serviceAccount.name }}
  labels:
    {{- include "goti-common.labels" . | nindent 4 }}
  {{- with .Values.serviceAccount.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}
{{- end }}
