{{/*
테스트 API IP 허용목록 — 허용된 IP 외 /api/v1/test/* 접근 DENY

부하테스트·시드 스크립트 엔드포인트를 팀원 IP로만 제한한다.
Red Team 공격 시 테스트 유저 대량 생성 방지 목적.

사용 예시 (values.yaml):
  istioPolicy:
    testIpAllowlist:
      enabled: true
      allowedIps:
        - "221.152.162.218/32"
        - "팀원B_IP/32"
*/}}
{{- define "goti-common.authorizationpolicy-test-ip" -}}
{{- if and .Values.istioPolicy .Values.istioPolicy.testIpAllowlist .Values.istioPolicy.testIpAllowlist.enabled }}
{{- $fullname := include "goti-common.fullname" . }}
{{- $labels := include "goti-common.labels" . }}
{{- $selectorLabels := include "goti-common.selectorLabels" . }}
{{- $policy := .Values.istioPolicy.testIpAllowlist }}
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: {{ $fullname }}-test-ip-allowlist
  labels:
    {{- $labels | nindent 4 }}
spec:
  selector:
    matchLabels:
      {{- $selectorLabels | nindent 6 }}
  action: DENY
  rules:
    - from:
        - source:
            notRemoteIpBlocks:
              {{- range $policy.allowedIps }}
              - {{ . | quote }}
              {{- end }}
      to:
        - operation:
            paths:
              - "/api/v1/test"
              - "/api/v1/test/*"
{{- end }}
{{- end }}
