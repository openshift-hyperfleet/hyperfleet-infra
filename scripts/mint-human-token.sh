#!/usr/bin/env bash
# shellcheck disable=SC2016
# The nested single-quoted script is evaluated inside the temporary curl pod.
# Mint a short-lived test-only human OIDC token from the in-cluster mock issuer.
# The JWT is the only stdout output. Diagnostics are written to stderr.

set -euo pipefail

NAMESPACE="${NAMESPACE:-}"
OIDC_ISSUER_MODE="${OIDC_ISSUER_MODE:-}"
AUTH_MODE="${AUTH_MODE:-NONE}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777}"
TENANT_MODEL="${TENANT_MODEL:-onprem}"
TOKEN_SUBJECT="${TOKEN_SUBJECT:-human@example.com}"
TOKEN_TENANT="${TOKEN_TENANT:-}"
TOKEN_SUBTENANT="${TOKEN_SUBTENANT:-}"
TOKEN_MISSING_REQUIRED="${TOKEN_MISSING_REQUIRED:-false}"
TOKEN_AUDIENCE="${TOKEN_AUDIENCE:-hyperfleet-api}"

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: required command not found: $1" >&2
        exit 1
    }
}

validate_value() {
    local name="$1"
    local value="$2"
    if [[ ! "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._:@+-]*$ ]]; then
        echo "ERROR: $name contains unsupported characters" >&2
        exit 1
    fi
}

require_command kubectl
require_command jq

if [[ -z "$NAMESPACE" ]]; then
    echo "ERROR: NAMESPACE is required" >&2
    exit 1
fi
if [[ "$OIDC_ISSUER_MODE" != "mock" ]]; then
    echo "ERROR: mint-human-token requires OIDC_ISSUER_MODE=mock (got '${OIDC_ISSUER_MODE:-unset}')" >&2
    exit 1
fi
if [[ "$AUTH_MODE" != "EDGE" && "$AUTH_MODE" != "EDGE+API" ]]; then
    echo "ERROR: mint-human-token requires AUTH_MODE=EDGE or EDGE+API" >&2
    exit 1
fi
case "$TENANT_MODEL" in
    onprem)
        required_claim="org_id"
        optional_claim="project_id"
        ;;
    oracle)
        required_claim="tenancy_ocid"
        optional_claim="compartment_id"
        ;;
    *)
        echo "ERROR: TENANT_MODEL must be onprem or oracle (got '$TENANT_MODEL')" >&2
        exit 1
        ;;
esac
case "$TOKEN_MISSING_REQUIRED" in
    true|false) ;;
    *)
        echo "ERROR: TOKEN_MISSING_REQUIRED must be true or false" >&2
        exit 1
        ;;
esac
validate_value TOKEN_SUBJECT "$TOKEN_SUBJECT"
validate_value TOKEN_AUDIENCE "$TOKEN_AUDIENCE"
if [[ "$TOKEN_MISSING_REQUIRED" == "false" && -z "$TOKEN_TENANT" ]]; then
    echo "ERROR: TOKEN_TENANT is required for a positive token ($required_claim)" >&2
    exit 1
fi
if [[ -n "$TOKEN_TENANT" ]]; then
    validate_value TOKEN_TENANT "$TOKEN_TENANT"
fi
if [[ -n "$TOKEN_SUBTENANT" ]]; then
    validate_value TOKEN_SUBTENANT "$TOKEN_SUBTENANT"
fi

if [[ "$TOKEN_MISSING_REQUIRED" == "true" ]]; then
    mapping="hyperfleet-${TENANT_MODEL}-missing"
elif [[ -n "$TOKEN_SUBTENANT" ]]; then
    mapping="hyperfleet-${TENANT_MODEL}-full"
else
    mapping="hyperfleet-${TENANT_MODEL}-required"
fi

issuer_url="http://hyperfleet-mock-oidc.${NAMESPACE}.svc.cluster.local:8080/default"
pod_name="hf-human-token-$(date +%s)-${RANDOM}"
cleanup() {
    kubectl delete pod "$pod_name" --namespace "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

printf 'Minting human token: mode=mock model=%s required_claim=%s optional_claim=%s mapping=%s\n' \
    "$TENANT_MODEL" "$required_claim" "$optional_claim" "$mapping" >&2
kubectl wait --for=condition=Available deployment/hyperfleet-mock-oidc \
    --namespace "$NAMESPACE" --timeout=120s >/dev/null

# Values are sent over pod stdin rather than put in kubectl command arguments or
# Kubernetes object fields. The temporary pod is deleted on every exit path.
response=$({
    printf '%s\n' "$TOKEN_SUBJECT"
    printf '%s\n' "$TOKEN_TENANT"
    printf '%s\n' "$TOKEN_SUBTENANT"
    printf '%s\n' "$mapping"
    printf '%s\n' "$TOKEN_AUDIENCE"
} | kubectl run "$pod_name" \
    --namespace "$NAMESPACE" \
    --labels=app.kubernetes.io/component=token-helper \
    --image="$CURL_IMAGE" \
    --restart=Never \
    --rm \
    --quiet \
    --stdin \
    --attach \
    --command -- sh -c '
set -eu
read -r subject
read -r tenant
read -r subtenant
read -r mapping
read -r audience
issuer_url="$1"

curl -fsS --connect-timeout 5 --max-time 15 \
    -X POST "${issuer_url%/}/token" \
    -u "hyperfleet-human-helper:" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_id=hyperfleet-human-helper" \
    --data-urlencode "scope=${mapping}" \
    --data-urlencode "audience=${audience}" \
    --data-urlencode "subject=${subject}" \
    --data-urlencode "org_id=${tenant}" \
    --data-urlencode "tenancy_ocid=${tenant}" \
    --data-urlencode "project_id=${subtenant}" \
    --data-urlencode "compartment_id=${subtenant}"
' -- "$issuer_url"
)
if ! token=$(printf '%s' "$response" | jq -er \
    '.access_token | select(type == "string" and length > 0)' 2>/dev/null); then
    printf '%s\n' "ERROR: mock issuer returned no access_token" >&2
    exit 1
fi
printf '%s\n' "$token"
