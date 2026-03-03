{{- define "goti-common.deployment" -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "goti-common.fullname" . }}
  labels:
    {{- include "goti-common.labels" . | nindent 4 }}
spec:
  {{- if not .Values.autoscaling.enabled }}
  replicas: {{ .Values.replicaCount }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "goti-common.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      annotations:
        sidecar.istio.io/inject: "true"
        {{- with .Values.podAnnotations }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      labels:
        {{- include "goti-common.selectorLabels" . | nindent 8 }}
    spec:
      {{- if .Values.serviceAccount.create }}
      serviceAccountName: {{ default (include "goti-common.fullname" .) .Values.serviceAccount.name }}
      {{- end }}
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: {{ default "http" .Values.service.name }}
              containerPort: {{ .Values.service.port }}
              protocol: TCP
          {{- if .Values.probes }}
          {{- with .Values.probes.liveness }}
          livenessProbe:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with .Values.probes.readiness }}
          readinessProbe:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- end }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          {{- with .Values.env }}
          env:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with .Values.envFrom }}
          envFrom:
            {{- toYaml . | nindent 12 }}
          {{- end }}
      {{- with .Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
{{- end }}
