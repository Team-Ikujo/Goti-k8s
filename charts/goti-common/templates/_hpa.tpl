{{- define "goti-common.hpa" -}}
{{- if .Values.autoscaling.enabled }}
{{- if and .Values.autoscaling.keda .Values.autoscaling.keda.enabled }}
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: {{ include "goti-common.fullname" . }}
  labels:
    {{- include "goti-common.labels" . | nindent 4 }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ include "goti-common.fullname" . }}
  minReplicaCount: {{ .Values.autoscaling.minReplicas }}
  maxReplicaCount: {{ .Values.autoscaling.maxReplicas }}
  cooldownPeriod: {{ .Values.autoscaling.keda.cooldownPeriod | default 60 }}
  {{- /* hasKey: 0 같은 falsy 값을 보존 (with는 0/empty를 skip).
         특히 idleReplicaCount=0 (scale-to-zero)은 KEDA의 핵심 유효 값. */}}
  {{- if hasKey .Values.autoscaling.keda "pollingInterval" }}
  pollingInterval: {{ .Values.autoscaling.keda.pollingInterval }}
  {{- end }}
  {{- if hasKey .Values.autoscaling.keda "idleReplicaCount" }}
  idleReplicaCount: {{ .Values.autoscaling.keda.idleReplicaCount }}
  {{- end }}
  {{- with .Values.autoscaling.keda.advanced }}
  advanced:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.autoscaling.keda.fallback }}
  fallback:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  triggers:
    {{- toYaml .Values.autoscaling.keda.triggers | nindent 4 }}
{{- else }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "goti-common.fullname" . }}
  labels:
    {{- include "goti-common.labels" . | nindent 4 }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ include "goti-common.fullname" . }}
  minReplicas: {{ .Values.autoscaling.minReplicas }}
  maxReplicas: {{ .Values.autoscaling.maxReplicas }}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ .Values.autoscaling.targetCPUUtilizationPercentage }}
{{- end }}
{{- end }}
{{- end }}
