{{/*
서비스별 Istio RequestAuthentication — JWT 검증을 서비스 메시 레벨에서 수행

Istio sidecar가 JWT를 검증하고 claim을 헤더로 변환한다.
forwardOriginalToken: true → Spring Boot에서도 원본 토큰 접근 가능
outputClaimToHeaders → sub→X-User-Id, role→X-User-Role 변환

사용 예시 (values.yaml):
  istioPolicy:
    requestAuthentication:
      enabled: true
      issuer: "goti-user-service"
      jwksUri: "http://goti-user-dev.goti.svc.cluster.local:8080/.well-known/jwks.json"
      outputClaimToHeaders:
        - header: "X-User-Id"
          claim: "sub"
        - header: "X-User-Role"
          claim: "role"
*/}}
{{- define "goti-common.requestauthentication" -}}
{{- if and .Values.istioPolicy .Values.istioPolicy.requestAuthentication .Values.istioPolicy.requestAuthentication.enabled }}
{{- $fullname := include "goti-common.fullname" . }}
{{- $labels := include "goti-common.labels" . }}
{{- $selectorLabels := include "goti-common.selectorLabels" . }}
{{- $ra := .Values.istioPolicy.requestAuthentication }}
---
apiVersion: security.istio.io/v1
kind: RequestAuthentication
metadata:
  name: {{ $fullname }}-jwt
  labels:
    {{- $labels | nindent 4 }}
spec:
  selector:
    matchLabels:
      {{- $selectorLabels | nindent 6 }}
  jwtRules:
    - issuer: {{ $ra.issuer | quote }}
      jwksUri: {{ $ra.jwksUri | quote }}
      forwardOriginalToken: {{ $ra.forwardOriginalToken | default true }}
      {{- if $ra.outputClaimToHeaders }}
      outputClaimToHeaders:
        {{- range $ra.outputClaimToHeaders }}
        - header: {{ .header | quote }}
          claim: {{ .claim | quote }}
        {{- end }}
      {{- end }}
{{- end }}
{{- end }}
