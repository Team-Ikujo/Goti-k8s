{{- define "goti-common.gateway" -}}
{{- if .Values.gateway.enabled }}
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: {{ include "goti-common.fullname" . }}
  labels:
    {{- include "goti-common.labels" . | nindent 4 }}
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        {{- range .Values.gateway.hosts }}
        - {{ . | quote }}
        {{- end }}
---
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
    - {{ include "goti-common.fullname" . }}
  http:
    - route:
        - destination:
            host: {{ include "goti-common.fullname" . }}
            port:
              number: {{ .Values.service.port }}
{{- end }}
{{- end }}
