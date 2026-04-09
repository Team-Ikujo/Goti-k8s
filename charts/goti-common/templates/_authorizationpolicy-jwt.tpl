{{/*
JWT 필수 강제 AuthorizationPolicy — JWT 없는 요청을 DENY

RequestAuthentication은 JWT가 있으면 검증하지만, 없는 요청은 통과시킨다.
이 AuthorizationPolicy가 인증 필요 경로에 JWT를 필수로 강제한다.
공개 API 경로는 excludePaths로 제외한다.

사용 예시 (values.yaml):
  istioPolicy:
    jwtAuthorizationPolicy:
      enabled: true
      excludePaths:
        - "/api/v1/auth/*"
        - "/api/v1/stadiums/*"
        - "/api/v1/games/*"
        - "/actuator/*"
        - "/swagger-ui/*"
        - "/v3/api-docs/*"
        - "/.well-known/*"
*/}}
{{- define "goti-common.authorizationpolicy-jwt" -}}
{{- if and .Values.istioPolicy .Values.istioPolicy.jwtAuthorizationPolicy .Values.istioPolicy.jwtAuthorizationPolicy.enabled }}
{{- $fullname := include "goti-common.fullname" . }}
{{- $labels := include "goti-common.labels" . }}
{{- $selectorLabels := include "goti-common.selectorLabels" . }}
{{- $policy := .Values.istioPolicy.jwtAuthorizationPolicy }}
{{- /* /internal/* 경로는 서비스 간 내부 호출 전용 — JWT 불필요 (mTLS SA 인증) */}}
{{- $excludePaths := concat (list "/internal/*") ($policy.excludePaths | default list) }}
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: {{ $fullname }}-require-jwt
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
            notRequestPrincipals: ["*"]
      to:
        - operation:
            notPaths:
              {{- range $excludePaths }}
              - {{ . | quote }}
              {{- end }}
{{- end }}
{{- end }}
