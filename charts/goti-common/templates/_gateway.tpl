{{- define "goti-common.gateway" -}}
{{- if .Values.gateway.enabled }}
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: {{ include "goti-common.fullname" . }}
  labels:
    {{- include "goti-common.labels" . | nindent 4 }}
spec:
  hosts:
    {{- range .Values.gateway.hosts }}
    - {{ . | quote }}
    {{- end }}
  gateways:
    - {{ .Values.gateway.gatewayRef | default (include "goti-common.fullname" .) }}
  http:
    {{- if .Values.gateway.matchPrefixes }}
    - match:
        {{- range .Values.gateway.matchPrefixes }}
        - uri:
            prefix: {{ . | quote }}
        {{- end }}
      route:
        - destination:
            host: {{ include "goti-common.fullname" . }}
            port:
              number: {{ .Values.service.port }}
    {{- else }}
    - route:
        - destination:
            host: {{ include "goti-common.fullname" . }}
            port:
              number: {{ .Values.service.port }}
    {{- end }}
{{- end }}
{{- end }}
