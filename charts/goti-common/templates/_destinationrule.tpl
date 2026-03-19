{{/*
DestinationRule — Circuit breaker, connection pool, load balancing
Phase 2: Resilience 설정

사용 예시 (values.yaml):
  istioPolicy:
    destinationRule:
      enabled: true
      connectionPool:
        tcp:
          maxConnections: 100
          connectTimeout: 5s
        http:
          maxRequestsPerConnection: 100
          maxRetries: 3
      outlierDetection:
        consecutive5xxErrors: 5
        interval: 30s
        baseEjectionTime: 30s
        maxEjectionPercent: 50
      loadBalancer:
        simple: LEAST_REQUEST
*/}}
{{- define "goti-common.destinationrule" -}}
{{- if and .Values.istioPolicy .Values.istioPolicy.destinationRule .Values.istioPolicy.destinationRule.enabled }}
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: {{ include "goti-common.fullname" . }}
  labels:
    {{- include "goti-common.labels" . | nindent 4 }}
spec:
  host: {{ include "goti-common.fullname" . }}
  trafficPolicy:
    {{- with .Values.istioPolicy.destinationRule.connectionPool }}
    connectionPool:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with .Values.istioPolicy.destinationRule.outlierDetection }}
    outlierDetection:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with .Values.istioPolicy.destinationRule.loadBalancer }}
    loadBalancer:
      {{- toYaml . | nindent 6 }}
    {{- end }}
{{- end }}
{{- end }}
