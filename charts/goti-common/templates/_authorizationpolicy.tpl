{{/*
서비스별 AuthorizationPolicy — 서비스 간 통신 허용 규칙
deny-all (goti-policy chart)과 함께 사용하여 allowlist 패턴 구현

사용 예시 (values.yaml):
  istioPolicy:
    authorizationPolicy:
      enabled: true
      allowFrom:
        - name: from-payment
          rules:
            - from:
                - source:
                    principals: ["cluster.local/ns/goti/sa/goti-payment-dev"]
              to:
                - operation:
                    paths: ["/api/v1/orders/*"]
                    methods: ["POST"]
*/}}
{{- define "goti-common.authorizationpolicy" -}}
{{- if and .Values.istioPolicy .Values.istioPolicy.authorizationPolicy .Values.istioPolicy.authorizationPolicy.enabled }}
{{- $fullname := include "goti-common.fullname" . }}
{{- $labels := include "goti-common.labels" . }}
{{- $selectorLabels := include "goti-common.selectorLabels" . }}
{{- /* /internal/* blanket ALLOW — goti namespace 내 SA만 허용 (mTLS 인증) */}}
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: {{ $fullname }}-from-mesh-internal
  labels:
    {{- $labels | nindent 4 }}
spec:
  selector:
    matchLabels:
      {{- $selectorLabels | nindent 6 }}
  action: ALLOW
  rules:
    - from:
        - source:
            namespaces: ["goti"]
      to:
        - operation:
            paths: ["/internal/*"]
{{- range .Values.istioPolicy.authorizationPolicy.allowFrom }}
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: {{ $fullname }}-{{ .name }}
  labels:
    {{- $labels | nindent 4 }}
spec:
  selector:
    matchLabels:
      {{- $selectorLabels | nindent 6 }}
  action: ALLOW
  rules:
    {{- toYaml .rules | nindent 4 }}
{{- end }}
{{- end }}
{{- end }}
