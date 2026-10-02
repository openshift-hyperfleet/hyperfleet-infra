#!/usr/bin/env bash
# Ensure Kind exposes the standard ServiceAccount OIDC discovery and JWKS
# endpoints to anonymous clients. hyperfleet-api fetches the advertised JWKS
# endpoint without a bearer token. Other providers publish their own endpoint.

set -euo pipefail

AUTH_MODE="${AUTH_MODE:-NONE}"

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: required command not found: $1" >&2
        exit 1
    }
}

if [[ "$AUTH_MODE" != "API" ]]; then
    echo "[NOTE: Skipping Kubernetes OIDC discovery prerequisite (AUTH_MODE=$AUTH_MODE)]"
    exit 0
fi

require_command kubectl

if [[ $(kubectl config current-context) != kind-* ]]; then
    echo "[NOTE: Kubernetes OIDC discovery prerequisite is managed by the provider]"
    exit 0
fi

kubectl create clusterrolebinding hyperfleet-anonymous-service-account-issuer-discovery \
    --clusterrole=system:service-account-issuer-discovery \
    --group=system:unauthenticated \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "OK: Kind ServiceAccount OIDC discovery is publicly readable"
