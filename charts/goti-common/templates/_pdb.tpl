{{- define "goti-common.pdb" -}}
{{- if .Values.pdb.enabled }}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "goti-common.fullname" . }}
  labels:
    {{- include "goti-common.labels" . | nindent 4 }}
spec:
  minAvailable: {{ .Values.pdb.minAvailable }}
  selector:
    matchLabels:
      {{- include "goti-common.selectorLabels" . | nindent 6 }}
{{- end }}
{{- end }}
