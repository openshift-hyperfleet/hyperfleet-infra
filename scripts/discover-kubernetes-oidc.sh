#!/usr/bin/env bash
# Emit the current cluster's public ServiceAccount OIDC configuration for
# HyperFleet API. This script is read-only so Helmfile build/template stays
# side-effect free; Kind's anonymous issuer-discovery prerequisite is handled
# by scripts/ensure-kubernetes-oidc-discovery.sh during installation.

set -euo pipefail

NAMESPACE="${1:?namespace argument is required}"

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: required command not found: $1" >&2
        exit 1
    }
}

require_command kubectl
require_command jq

discovery=$(kubectl get --raw='/.well-known/openid-configuration')
issuer=$(jq -er '.issuer | select(type == "string" and test("^https://[^[:space:]]+$"))' <<<"$discovery")
jwks_url=$(jq -er '.jwks_uri | select(type == "string" and test("^https://[^[:space:]]+$"))' <<<"$discovery")
issuer_host=${issuer#https://}
issuer_host=${issuer_host%%/*}

# GKE's discovery document can advertise the cluster-internal JWKS service
# address, which requires a bearer token. hyperfleet-api intentionally fetches
# remote JWKS anonymously, so use GKE's public JWKS endpoint instead.
if [[ "$issuer_host" == "container.googleapis.com" ]]; then
    jwks_url="${issuer%/}/jwks"
fi

cat <<EOF
issuer_url: "$issuer"
jwk_cert_url: "$jwks_url"
# hyperfleet-api appends this CA to the system pool, so it supports both
# Kubernetes-internal endpoints and public GKE JWKS endpoints.
jwk_cert_ca_file: "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
identity_claim_pattern: "^system:serviceaccount:${NAMESPACE}:.*$"
EOF
