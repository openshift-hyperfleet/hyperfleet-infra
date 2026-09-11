#!/usr/bin/env bash
# shellcheck disable=SC2016
# The nested single-quoted script is evaluated inside the temporary curl pod.
# Mint a short-lived test-only human OIDC token from the in-cluster mock issuer.
# The JWT is the only stdout output. Diagnostics are written to stderr.

set -euo pipefail

NAMESPACE="${NAMESPACE:-}"
OIDC_ISSUER_MODE="${OIDC_ISSUER_MODE:-}"
MOCK_OIDC_SERVICE="${MOCK_OIDC_SERVICE:-hyperfleet-mock-oidc}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777}"
TENANT_MODEL="${TENANT_MODEL:-onprem}"
TOKEN_SUBJECT="${TOKEN_SUBJECT:-human@example.com}"
TOKEN_TENANT="${TOKEN_TENANT:-}"
TOKEN_SUBTENANT="${TOKEN_SUBTENANT:-}"
TOKEN_MISSING_REQUIRED="${TOKEN_MISSING_REQUIRED:-false}"

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

if [[ -z "$NAMESPACE" ]]; then
    echo "ERROR: NAMESPACE is required" >&2
    exit 1
fi
if [[ "$OIDC_ISSUER_MODE" != "mock" ]]; then
    echo "ERROR: mint-human-token requires OIDC_ISSUER_MODE=mock (got '${OIDC_ISSUER_MODE:-unset}')" >&2
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

issuer_url="http://${MOCK_OIDC_SERVICE}.${NAMESPACE}.svc.cluster.local:8080/default"
pod_name="hf-human-token-$(date +%s)-${RANDOM}"
cleanup() {
    kubectl delete pod "$pod_name" --namespace "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

printf 'Minting human token: mode=mock model=%s required_claim=%s optional_claim=%s mapping=%s\n' \
    "$TENANT_MODEL" "$required_claim" "$optional_claim" "$mapping" >&2
kubectl wait --for=condition=Available "deployment/${MOCK_OIDC_SERVICE}" \
    --namespace "$NAMESPACE" --timeout=120s >/dev/null

# Values are sent over pod stdin rather than put in kubectl command arguments or
# Kubernetes object fields. The temporary pod is deleted on every exit path.
{
    printf '%s\n' "$TOKEN_SUBJECT"
    printf '%s\n' "$TOKEN_TENANT"
    printf '%s\n' "$TOKEN_SUBTENANT"
    printf '%s\n' "$mapping"
} | kubectl run "$pod_name" \
    --namespace "$NAMESPACE" \
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
issuer_url="$1"

response=$(curl -fsS --connect-timeout 5 --max-time 15 \
    -X POST "${issuer_url%/}/token" \
    -u "hyperfleet-human-helper:" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_id=hyperfleet-human-helper" \
    --data-urlencode "scope=${mapping}" \
    --data-urlencode "subject=${subject}" \
    --data-urlencode "org_id=${tenant}" \
    --data-urlencode "tenancy_ocid=${tenant}" \
    --data-urlencode "project_id=${subtenant}" \
    --data-urlencode "compartment_id=${subtenant}")
token=$(printf "%s" "$response" | tr -d "\n" | sed -n "s/.*\"access_token\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p")
if [ -z "$token" ]; then
    printf "%s\n" "ERROR: mock issuer returned no access_token" >&2
    exit 1
fi
printf "%s\n" "$token"
' -- "$issuer_url"
