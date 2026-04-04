{{/*
서비스별 Istio RequestAuthentication — JWT 검증을 서비스 메시 레벨에서 수행

Istio sidecar가 JWT를 검증하고 claim을 헤더로 변환한다.
forwardOriginalToken: true → Spring Boot에서도 원본 토큰 접근 가능
outputClaimToHeaders → sub→X-User-Id, role→X-User-Role 변환

JWKS 소스 우선순위:
  1. jwksFromSecret — ExternalSecret이 만든 Secret에서 동적 조회 (권장)
  2. jwks           — 인라인 하드코딩 (비권장, 키 로테이션 시 수동 수정 필요)
  3. jwksUri        — Istio가 HTTP로 JWKS 엔드포인트 조회 (STRICT mTLS 환경에서 불가)

사용 예시 (values.yaml):
  istioPolicy:
    requestAuthentication:
      enabled: true
      issuer: "goti-user-service"
      jwksFromSecret:
        name: ""   # 비워두면 {fullname}-secrets 자동 사용
        key: "ISTIO_JWKS"
*/}}
{{- define "goti-common.requestauthentication" -}}
{{- if and .Values.istioPolicy .Values.istioPolicy.requestAuthentication .Values.istioPolicy.requestAuthentication.enabled }}
{{- $fullname := include "goti-common.fullname" . }}
{{- $labels := include "goti-common.labels" . }}
{{- $selectorLabels := include "goti-common.selectorLabels" . }}
{{- $ra := .Values.istioPolicy.requestAuthentication }}
{{- /* JWKS 값 결정: jwksFromSecret > jwks > jwksUri */}}
{{- $jwksValue := "" }}
{{- if and $ra.jwksFromSecret $ra.jwksFromSecret.key }}
  {{- $secretName := $ra.jwksFromSecret.name | default (printf "%s-secrets" $fullname) }}
  {{- $secretKey := $ra.jwksFromSecret.key }}
  {{- $secret := (lookup "v1" "Secret" .Release.Namespace $secretName) }}
  {{- if and $secret $secret.data (index $secret.data $secretKey) }}
    {{- $jwksValue = index $secret.data $secretKey | b64dec }}
  {{- end }}
{{- end }}
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
      {{- if $jwksValue }}
      jwks: {{ $jwksValue | quote }}
      {{- else if $ra.jwks }}
      jwks: {{ $ra.jwks | quote }}
      {{- else if $ra.jwksUri }}
      jwksUri: {{ $ra.jwksUri | quote }}
      {{- end }}
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
