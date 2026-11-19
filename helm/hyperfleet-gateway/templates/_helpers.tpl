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

{{/* Names of short-lived Helm hook resources for wristband key lifecycle. */}}
{{- define "hyperfleet-gateway.wristbandProvisionerName" -}}
{{- printf "%s-wristband-key-provisioner" (include "hyperfleet-gateway.fullname" . | trunc 37) | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "hyperfleet-gateway.wristbandCleanupName" -}}
{{- printf "%s-wristband-key-cleanup" (include "hyperfleet-gateway.fullname" . | trunc 42) | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "hyperfleet-gateway.wristbandSweepName" -}}
{{- printf "%s-wristband-key-sweep" (include "hyperfleet-gateway.fullname" . | trunc 45) | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/*
JSON list of wristband signing Secret names, signer first. Authorino signs with
the first key and publishes all of them. make rotate-wristband-key sets
auth.wristband.signingKeys. Without it the list is what the live AuthConfig
already has, so a plain deploy keeps a rotated key. A fresh install (or helm
template, where lookup returns nothing) gets signingKeySecretName.
*/}}
{{- define "hyperfleet-gateway.wristbandSigningKeys" -}}
{{- $keys := .Values.auth.wristband.signingKeys -}}
{{- if not $keys -}}
{{- $live := lookup "authorino.kuadrant.io/v1beta3" "AuthConfig" .Release.Namespace "hyperfleet-tenant-policy" -}}
{{- range dig "spec" "response" "success" "dynamicMetadata" "wristband" "wristband" "signingKeyRefs" (list) $live -}}
{{- $keys = append $keys .name -}}
{{- end -}}
{{- end -}}
{{- if not $keys -}}
{{- $keys = list .Values.auth.wristband.signingKeySecretName -}}
{{- end -}}
{{- toJson $keys -}}
{{- end }}

{{/* JSON list of labeled signing Secrets the AuthConfig will not list, which a hook may delete. */}}
{{- define "hyperfleet-gateway.wristbandStaleKeys" -}}
{{- $keep := list -}}
{{- if eq .Values.auth.mode "EDGE+API" -}}
{{- $keep = include "hyperfleet-gateway.wristbandSigningKeys" . | fromJsonArray -}}
{{- end -}}
{{- $stale := list -}}
{{- range (lookup "v1" "Secret" .Release.Namespace "").items -}}
{{- if and (hasKey (.metadata.labels | default dict) "hyperfleet.io/wristband-signing-key") (not (has .metadata.name $keep)) -}}
{{- $stale = append $stale .metadata.name -}}
{{- end -}}
{{- end -}}
{{- toJson $stale -}}
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
