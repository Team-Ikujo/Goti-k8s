{{- define "goti-common.service" -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "goti-common.fullname" . }}
  labels:
    {{- include "goti-common.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: {{ default "http" .Values.service.name }}
      protocol: TCP
      name: {{ default "http" .Values.service.name }}
  selector:
    {{- include "goti-common.selectorLabels" . | nindent 4 }}
{{- end }}
