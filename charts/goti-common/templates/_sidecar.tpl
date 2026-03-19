{{/*
Sidecar — Egress 트래픽 제한 (Phase 2, 기본 비활성화)
활성화 시 해당 워크로드의 Envoy가 지정된 호스트로만 egress 가능

사용 예시 (values.yaml):
  istioPolicy:
    sidecar:
      enabled: true
      egress:
        - hosts:
            - "istio-system/*"
            - "./goti-ticketing-dev.goti.svc.cluster.local"
            - "~/*.amazonaws.com"
*/}}
{{- define "goti-common.sidecar" -}}
{{- if and .Values.istioPolicy .Values.istioPolicy.sidecar .Values.istioPolicy.sidecar.enabled }}
apiVersion: networking.istio.io/v1
kind: Sidecar
metadata:
  name: {{ include "goti-common.fullname" . }}
  labels:
    {{- include "goti-common.labels" . | nindent 4 }}
spec:
  workloadSelector:
    labels:
      {{- include "goti-common.selectorLabels" . | nindent 6 }}
  egress:
    {{- toYaml .Values.istioPolicy.sidecar.egress | nindent 4 }}
{{- end }}
{{- end }}
