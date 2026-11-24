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
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
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
Name of the Authorino CR. Single source of truth for authorino.yaml and the
SecurityPolicy/BackendTLSPolicy that reach Authorino, which derive their names
from it via the operator's naming convention ("<name>-authorino" ServiceAccount,
"<name>-authorino-authorization" Service).
*/}}
{{- define "hyperfleet-gateway.authorinoName" -}}
{{- .Values.authorino.name -}}
{{- end }}

{{/* Name of the Authorino authorization Service the operator creates. */}}
{{- define "hyperfleet-gateway.authorinoAuthorizationService" -}}
{{- printf "%s-authorino-authorization" (include "hyperfleet-gateway.authorinoName" .) -}}
{{- end }}

{{/*
Name of the Gateway and its EnvoyProxy: the release name. Envoy Gateway derives
the proxy Deployment and pod names from it, and the API NetworkPolicy selects the
pods by it, so it is not a value.
*/}}
{{- define "hyperfleet-gateway.gatewayName" -}}
{{- include "hyperfleet-gateway.fullname" . -}}
{{- end }}

{{/*
The headers removed from every client request before authorization runs. The
tenant headers of both models and the two Authorino-set headers are always
stripped, so a values override cannot leave a trusted header forgeable:
headers.stripOverride only adds to this list.
*/}}
{{- define "hyperfleet-gateway.stripHeaders" -}}
{{- $fixed := list "x-tenant-org" "x-tenant-project" "x-tenant-tenancy-ocid" "x-tenant-compartment" "x-hyperfleet-system" "x-hyperfleet-identity" -}}
{{- toJson (concat $fixed .Values.headers.stripOverride | uniq) -}}
{{- end }}

{{/*
The fullname plus a suffix. Not truncated, like the GatewayClass name: these are
not DNS labels, their names may have 253 characters, and a fullname (63) plus a
suffix never gets near that, so two suffixes never collapse into one name.
Call with (dict "root" . "suffix" "upstream").
*/}}
{{- define "hyperfleet-gateway.suffixedName" -}}
{{- printf "%s-%s" (include "hyperfleet-gateway.fullname" .root) .suffix -}}
{{- end }}

{{/* Name of the Service Envoy Gateway generates for the Gateway. */}}
{{- define "hyperfleet-gateway.serviceName" -}}
{{- include "hyperfleet-gateway.fullname" . -}}
{{- end }}

{{/* Labels Envoy Gateway puts on the proxy pods of this release's Gateway. */}}
{{- define "hyperfleet-gateway.proxyPodLabels" -}}
gateway.envoyproxy.io/owning-gateway-name: {{ include "hyperfleet-gateway.gatewayName" . }}
gateway.envoyproxy.io/owning-gateway-namespace: {{ .Release.Namespace }}
{{- end }}

{{/*
JSON list of the listeners that carry routes and require authentication: every
listener except one marked `authenticated: false`.
*/}}
{{- define "hyperfleet-gateway.authenticatedListeners" -}}
{{- $names := list -}}
{{- range .Values.gateway.listeners -}}
{{- if ne (toString .authenticated) "false" -}}
{{- $names = append $names .name -}}
{{- end -}}
{{- end -}}
{{- toJson $names -}}
{{- end }}

{{/* Secret holding the upstream's serving certificate. */}}
{{- define "hyperfleet-gateway.upstreamTLSSecretName" -}}
{{- default (printf "%s-server-cert" .Values.upstream.host) .Values.upstream.tlsSecretName -}}
{{- end }}

{{/* Secrets holding Authorino's two listener certificates. */}}
{{- define "hyperfleet-gateway.authorinoAuthorizationTLSSecretName" -}}
{{- printf "%s-server-cert" (include "hyperfleet-gateway.authorinoName" .) -}}
{{- end }}

{{- define "hyperfleet-gateway.authorinoOIDCTLSSecretName" -}}
{{- printf "%s-oidc-server-cert" (include "hyperfleet-gateway.authorinoName" .) -}}
{{- end }}

{{/*
Name of the AuthConfig this chart renders. The API's Helmfile values build its
wristband issuer URL from it, so it is not configurable.
*/}}
{{- define "hyperfleet-gateway.authConfigName" -}}
hyperfleet-tenant-policy
{{- end }}

{{/*
Checks that fail with a clear message instead of a nil dereference. Helm renders
templates in reverse alphabetical order, so every template that reads the policy
must include this before it does.
*/}}
{{- define "hyperfleet-gateway.validate" -}}
{{- $wristband := (.Values.authorino.policy | default dict).wristband | default dict -}}
{{- if and $wristband.enabled (not .Values.authorino.enabled) -}}
{{- fail "authorino.policy.wristband.enabled needs authorino.enabled: the wristband is issued by Authorino" -}}
{{- end -}}
{{- end }}

{{/* The AuthConfig this chart owns: only in the edge modes, and only with a policy. */}}
{{- define "hyperfleet-gateway.authConfigEnabled" -}}
{{- if and (include "hyperfleet-gateway.edgeAuthEnabled" .) .Values.authorino.policy -}}true{{- end -}}
{{- end }}

{{/* This is also the OIDC realm used by the API's Helmfile values. */}}
{{- define "hyperfleet-gateway.wristbandIssuer" -}}
{{- printf "https://%s-authorino-oidc.%s.svc:8083/%s/%s/wristband" (include "hyperfleet-gateway.authorinoName" .) .Release.Namespace .Release.Namespace (include "hyperfleet-gateway.authConfigName" .) -}}
{{- end }}

{{- define "hyperfleet-gateway.edgeAuthEnabled" -}}
{{- if .Values.authorino.enabled -}}true{{- end -}}
{{- end }}

{{/* Authorino issues a wristband (ADR-0034 EDGE+API): needs Authorino and its policy. */}}
{{- define "hyperfleet-gateway.wristbandEnabled" -}}
{{- $wristband := (.Values.authorino.policy | default dict).wristband | default dict -}}
{{- if and .Values.authorino.enabled $wristband.enabled -}}true{{- end -}}
{{- end }}

{{- define "hyperfleet-gateway.rootCASecretName" -}}
{{- printf "%s-ca-cert" (include "hyperfleet-gateway.fullname" .) -}}
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
authorino.policy.wristband.signingKeys. Without it the list is what the live
AuthConfig already has, so a plain deploy keeps a rotated key. A fresh install
(or helm template, where lookup returns nothing) gets signingKeySecretName.
*/}}
{{- define "hyperfleet-gateway.wristbandSigningKeys" -}}
{{- $wristband := (.Values.authorino.policy | default dict).wristband | default dict -}}
{{- $keys := $wristband.signingKeys | default list -}}
{{- if not $keys -}}
{{- $live := lookup "authorino.kuadrant.io/v1beta3" "AuthConfig" .Release.Namespace (include "hyperfleet-gateway.authConfigName" .) -}}
{{- range dig "spec" "response" "success" "dynamicMetadata" "wristband" "wristband" "signingKeyRefs" (list) $live -}}
{{- $keys = append $keys .name -}}
{{- end -}}
{{- end -}}
{{- if not $keys -}}
{{- $keys = list $wristband.signingKeySecretName -}}
{{- end -}}
{{- toJson $keys -}}
{{- end }}

{{/*
JSON list of signing Secrets labeled for this release that the AuthConfig will not
list, which a hook may delete. The label value is the release name, so a release
never sweeps the keys of another release in the same namespace.
*/}}
{{- define "hyperfleet-gateway.wristbandStaleKeys" -}}
{{- $keep := list -}}
{{- if include "hyperfleet-gateway.wristbandEnabled" . -}}
{{- $keep = include "hyperfleet-gateway.wristbandSigningKeys" . | fromJsonArray -}}
{{- end -}}
{{- $stale := list -}}
{{- range (lookup "v1" "Secret" .Release.Namespace "").items -}}
{{- if and (eq (get (.metadata.labels | default dict) "hyperfleet.io/wristband-signing-key") $.Release.Name) (not (has .metadata.name $keep)) -}}
{{- $stale = append $stale .metadata.name -}}
{{- end -}}
{{- end -}}
{{- toJson $stale -}}
{{- end }}
