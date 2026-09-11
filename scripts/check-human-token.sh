#!/usr/bin/env bash
# shellcheck disable=SC2016
# The nested single-quoted script is evaluated inside the temporary curl pod.
# Smoke-test the mock human issuer, Authorino gateway, and API tenant headers.
# This is intentionally narrower than the full gateway isolation suite.

set -euo pipefail

NAMESPACE="${NAMESPACE:-}"
OIDC_ISSUER_MODE="${OIDC_ISSUER_MODE:-}"
EXT_AUTHZ_ENABLED="${EXT_AUTHZ_ENABLED:-false}"
TENANT_ISOLATION_ENABLED="${TENANT_ISOLATION_ENABLED:-false}"
TENANT_MODEL="${TENANT_MODEL:-onprem}"
TOKEN_SUBJECT="${TOKEN_SUBJECT:-human@example.com}"
TOKEN_TENANT="${TOKEN_TENANT:-}"
TOKEN_SUBTENANT="${TOKEN_SUBTENANT:-}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777}"
MOCK_OIDC_SERVICE="${MOCK_OIDC_SERVICE:-hyperfleet-mock-oidc}"
GATEWAY_SERVICE="${GATEWAY_SERVICE:-hyperfleet-gateway}"

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: required command not found: $1" >&2
        exit 1
    }
}

require_command kubectl

if [[ -z "$NAMESPACE" ]]; then
    echo "ERROR: NAMESPACE is required" >&2
    exit 1
fi
if [[ "$OIDC_ISSUER_MODE" != "mock" ]]; then
    echo "ERROR: check-human-token requires OIDC_ISSUER_MODE=mock" >&2
    exit 1
fi
if [[ "$EXT_AUTHZ_ENABLED" != "true" ]]; then
    echo "ERROR: check-human-token requires EXT_AUTHZ_ENABLED=true" >&2
    exit 1
fi
if [[ "$TENANT_ISOLATION_ENABLED" != "true" ]]; then
    echo "ERROR: check-human-token requires TENANT_ISOLATION_ENABLED=true" >&2
    exit 1
fi
case "$TENANT_MODEL" in
    onprem)
        required_key="org"
        optional_key="project"
        ;;
    oracle)
        required_key="tenancy_ocid"
        optional_key="compartment_id"
        ;;
    *)
        echo "ERROR: TENANT_MODEL must be onprem or oracle" >&2
        exit 1
        ;;
esac

kubectl wait --for=condition=Available "deployment/${MOCK_OIDC_SERVICE}" \
    --namespace "$NAMESPACE" --timeout=120s >/dev/null
kubectl wait --for=condition=Ready "authconfig/hyperfleet-tenant-policy" \
    --namespace "$NAMESPACE" --timeout=120s >/dev/null

script_dir=$(dirname -- "$0")
SCRIPT_DIR=$(cd -- "$script_dir" && pwd)
cluster_id=""
created_cluster_name="hf-human-token-$(date +%s)-${RANDOM}"
api_path="/api/hyperfleet/v1"
temporary_pods=()

cleanup() {
    if [[ -n "$cluster_id" && -n "${valid_token:-}" ]]; then
        api_request DELETE "${api_path}/clusters/${cluster_id}" "$valid_token" "" >/dev/null 2>&1 || true
    fi
    for pod_name in "${temporary_pods[@]}"; do
        kubectl delete pod "$pod_name" --namespace "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT

api_request() {
    local method="$1"
    local path="$2"
    local token="$3"
    local body="${4:-}"
    local pod_name
    pod_name="hf-human-check-$(date +%s)-${RANDOM}"
    temporary_pods+=("$pod_name")

    printf '%s\n' "$token" | kubectl run "$pod_name" \
        --namespace "$NAMESPACE" \
        --image="$CURL_IMAGE" \
        --restart=Never \
        --rm \
        --quiet \
        --stdin \
        --attach \
        --command -- sh -c '
set -eu
read -r token
method="$1"
path="$2"
body="${3:-}"
gateway_service="$4"
response_file=/tmp/response.json
if [ -n "$body" ]; then
    status=$(curl -sS --connect-timeout 5 --max-time 20 -o "$response_file" -w "%{http_code}" \
        -X "$method" "http://${gateway_service}:8000${path}" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        --data-raw "$body")
else
    status=$(curl -sS --connect-timeout 5 --max-time 20 -o "$response_file" -w "%{http_code}" \
        -X "$method" "http://${gateway_service}:8000${path}" \
        -H "Authorization: Bearer ${token}")
fi
printf "%s\\n" "$status"
cat "$response_file"
' -- "$method" "$path" "$body" "$GATEWAY_SERVICE"
}

printf 'Checking human token propagation: mode=mock model=%s required_claim=%s optional_claim=%s\n' \
    "$TENANT_MODEL" "$required_key" "$optional_key" >&2

valid_token=$(TOKEN_MISSING_REQUIRED=false \
    TOKEN_SUBJECT="$TOKEN_SUBJECT" \
    TOKEN_TENANT="$TOKEN_TENANT" \
    TOKEN_SUBTENANT="$TOKEN_SUBTENANT" \
    TENANT_MODEL="$TENANT_MODEL" \
    OIDC_ISSUER_MODE=mock NAMESPACE="$NAMESPACE" \
    "$SCRIPT_DIR/mint-human-token.sh")

valid_response=$(api_request POST "${api_path}/clusters" "$valid_token" \
    "{\"kind\":\"Cluster\",\"name\":\"${created_cluster_name}\",\"spec\":{\"region\":\"us-east-1\"}}")
valid_status="${valid_response%%$'\n'*}"
valid_body="${valid_response#*$'\n'}"
if [[ "$valid_status" != "201" ]]; then
    echo "ERROR: valid token cluster creation returned HTTP $valid_status: $valid_body" >&2
    exit 1
fi
cluster_id=$(printf '%s' "$valid_body" | tr -d '\n' | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
if [[ -z "$cluster_id" ]]; then
    echo "ERROR: valid token response did not contain a cluster id" >&2
    exit 1
fi

compact_body=$(printf '%s' "$valid_body" | tr -d '[:space:]')
if ! printf '%s' "$compact_body" | grep -q "\"${required_key}\":\"${TOKEN_TENANT}\""; then
    echo "ERROR: API response did not propagate ${required_key}=${TOKEN_TENANT}" >&2
    exit 1
fi
if [[ -n "$TOKEN_SUBTENANT" ]]; then
    if ! printf '%s' "$compact_body" | grep -q "\"${optional_key}\":\"${TOKEN_SUBTENANT}\""; then
        echo "ERROR: API response did not propagate ${optional_key}=${TOKEN_SUBTENANT}" >&2
        exit 1
    fi
elif printf '%s' "$compact_body" | grep -q "\"${optional_key}\":\""; then
    echo "ERROR: API response unexpectedly contained optional ${optional_key}" >&2
    exit 1
fi
printf 'PASS: valid %s token created a resource with required and optional tenant propagation\n' "$TENANT_MODEL"

missing_token=$(TOKEN_MISSING_REQUIRED=true \
    TOKEN_SUBJECT="$TOKEN_SUBJECT" \
    TOKEN_TENANT="$TOKEN_TENANT" \
    TOKEN_SUBTENANT="$TOKEN_SUBTENANT" \
    TENANT_MODEL="$TENANT_MODEL" \
    OIDC_ISSUER_MODE=mock NAMESPACE="$NAMESPACE" \
    "$SCRIPT_DIR/mint-human-token.sh")
missing_response=$(api_request GET "${api_path}/clusters" "$missing_token")
missing_status="${missing_response%%$'\n'*}"
if [[ "$missing_status" != "403" ]]; then
    echo "ERROR: token missing ${required_key} returned HTTP $missing_status, expected 403" >&2
    exit 1
fi
printf 'PASS: token missing required %s claim was rejected with HTTP 403\n' "$required_key"

printf 'OK: human token source and gateway tenant propagation check passed (mode=mock model=%s)\n' "$TENANT_MODEL"
