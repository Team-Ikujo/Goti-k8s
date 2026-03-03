{{/*
Chart name truncated to 63 chars.
*/}}
{{- define "goti-common.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name.
Release name truncated to 63 chars.
*/}}
{{- define "goti-common.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Chart name and version for chart label.
*/}}
{{- define "goti-common.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "goti-common.labels" -}}
helm.sh/chart: {{ include "goti-common.chart" . }}
{{ include "goti-common.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: goti
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "goti-common.selectorLabels" -}}
app.kubernetes.io/name: {{ include "goti-common.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
