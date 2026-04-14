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
  {{- with .Values.autoscaling.keda.pollingInterval }}
  pollingInterval: {{ . }}
  {{- end }}
  {{- with .Values.autoscaling.keda.idleReplicaCount }}
  idleReplicaCount: {{ . }}
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
