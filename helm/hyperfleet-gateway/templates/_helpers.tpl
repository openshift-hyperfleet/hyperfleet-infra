{{/*
Expand the name of the chart.
*/}}
{{- define "hyperfleet-gateway.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "hyperfleet-gateway.fullname" -}}
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
{{- define "hyperfleet-gateway.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "hyperfleet-gateway.labels" -}}
helm.sh/chart: {{ include "hyperfleet-gateway.chart" . }}
{{ include "hyperfleet-gateway.selectorLabels" . }}
{{- if or .Values.image.tag .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "hyperfleet-gateway.selectorLabels" -}}
app.kubernetes.io/name: {{ include "hyperfleet-gateway.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Name of the Authorino CR. Single source of truth for authorino.yaml and
configmap.yaml's ext_authz cluster address, which derive their names from it
via the operator's naming convention ("<name>-authorino" ServiceAccount,
"<name>-authorino-authorization" Service).
*/}}
{{- define "hyperfleet-gateway.authorinoName" -}}
authorino
{{- end }}

{{/* This is also the OIDC realm used by the API's Helmfile values. */}}
{{- define "hyperfleet-gateway.wristbandIssuer" -}}
{{- printf "https://%s-authorino-oidc.%s.svc:8083/%s/hyperfleet-tenant-policy/wristband" (include "hyperfleet-gateway.authorinoName" .) .Release.Namespace .Release.Namespace -}}
{{- end }}

{{- define "hyperfleet-gateway.edgeAuthEnabled" -}}
{{- if has .Values.auth.mode (list "EDGE" "EDGE+API") -}}true{{- end -}}
{{- end }}

{{- define "hyperfleet-gateway.rootCASecretName" -}}
hyperfleet-gateway-ca-cert
{{- end }}

{{- define "hyperfleet-gateway.validateSecurity" -}}
{{- if not (has .Values.auth.mode (list "NONE" "EDGE" "API" "EDGE+API")) -}}
{{- fail "auth.mode must be NONE, EDGE, API, or EDGE+API" -}}
{{- end -}}
{{- if or (not .Values.tls.hyperfleetApiTLSSecretName) (not .Values.tls.authorinoAuthorizationTLSSecretName) (not .Values.tls.authorinoOIDCTLSSecretName) -}}
{{- fail "all internal TLS serving Secret names are required" -}}
{{- end -}}
{{- if and (eq .Values.auth.mode "EDGE+API") (not .Values.auth.wristband.signingKeySecretName) -}}
{{- fail "auth.wristband.signingKeySecretName is required in EDGE+API mode" -}}
{{- end -}}
{{- if and (eq .Values.auth.mode "EDGE+API") (not .Values.auth.wristband.audience) -}}
{{- fail "auth.wristband.audience is required in EDGE+API mode" -}}
{{- end -}}
{{- if and (eq .Values.auth.mode "EDGE+API") (le (int .Values.auth.wristband.tokenDuration) 0) -}}
{{- fail "auth.wristband.tokenDuration must be greater than zero in EDGE+API mode" -}}
{{- end -}}
{{- end }}

{{/*
Create the name of the ServiceAccount to use.
*/}}
{{- define "hyperfleet-gateway.serviceAccountName" -}}
{{- if .Values.deployment.serviceAccount.create }}
{{- default (include "hyperfleet-gateway.fullname" .) .Values.deployment.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.deployment.serviceAccount.name }}
{{- end }}
{{- end }}
