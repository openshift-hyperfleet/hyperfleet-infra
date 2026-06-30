{{/*
Expand the name of the chart.
*/}}
{{- define "namespace-cleaner.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "namespace-cleaner.fullname" -}}
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
Create chart name and version as used by the chart label.
*/}}
{{- define "namespace-cleaner.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "namespace-cleaner.labels" -}}
helm.sh/chart: {{ include "namespace-cleaner.chart" . }}
{{ include "namespace-cleaner.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Name for cluster-scoped resources (ClusterRole, ClusterRoleBinding).
Includes the release namespace so multiple installs don't collide.
*/}}
{{- define "namespace-cleaner.clusterResourceName" -}}
{{- printf "%s-%s" (include "namespace-cleaner.fullname" .) .Release.Namespace | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "namespace-cleaner.selectorLabels" -}}
app.kubernetes.io/name: {{ include "namespace-cleaner.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
