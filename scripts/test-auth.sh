#!/usr/bin/env bash
# Manually exercise the deployed gateway/API authentication modes.
# Successful requests expect HTTP 200; rejected credentials expect 401 or 403.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

AUTH_MODE="${AUTH_MODE:-}"
HELMFILE_ENV="${HELMFILE_ENV:-gcp}"
GATEWAY_SERVICE="${GATEWAY_SERVICE:-hyperfleet-gateway}"
GATEWAY_PORT="${GATEWAY_PORT:-8000}"
LOCAL_PORT="${LOCAL_PORT:-8000}"
BASE_URL="${BASE_URL:-http://127.0.0.1:${LOCAL_PORT}}"
TENANT_MODEL="${TENANT_MODEL:-onprem}"
TOKEN_SUBJECT="${TOKEN_SUBJECT:-human@example.com}"
TOKEN_TENANT="${TOKEN_TENANT:-}"
TOKEN_SUBTENANT="${TOKEN_SUBTENANT:-}"

AUTH_MODE=$(printf '%s' "$AUTH_MODE" | tr '[:lower:]' '[:upper:]')
case "$AUTH_MODE" in
    NONE|API|EDGE|EDGE+API) ;;
    *)
        echo "Usage: AUTH_MODE=NONE|API|EDGE|EDGE+API $0" >&2
        exit 2
        ;;
esac

if [[ -z "${NAMESPACE:-}" ]]; then
    case "$HELMFILE_ENV" in
        kind) NAMESPACE=hyperfleet-local ;;
        e2e-kind) NAMESPACE=hyperfleet-e2e ;;
        e2e-gcp)
            user_name=$(printf '%s' "${USER:-default}" | tr '[:upper:]' '[:lower:]')
            NAMESPACE="hyperfleet-e2e-${user_name}"
            ;;
        *) NAMESPACE=hyperfleet ;;
    esac
fi

export AUTH_MODE HELMFILE_ENV NAMESPACE

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: required command not found: $1" >&2
        exit 1
    }
}

require_command kubectl
require_command curl
require_command lsof
require_command make

if [[ "$AUTH_MODE" != "NONE" && -z "$TOKEN_TENANT" ]]; then
    echo "ERROR: TOKEN_TENANT is required to mint the human token (TENANT_MODEL=$TENANT_MODEL)" >&2
    echo "Example: TOKEN_TENANT=org-acme AUTH_MODE=$AUTH_MODE $0" >&2
    exit 2
fi

PF_PID=""
PF_LOG=""
cleanup() {
    if [[ -n "$PF_PID" ]]; then
        kill "$PF_PID" >/dev/null 2>&1 || true
        wait "$PF_PID" 2>/dev/null || true
    fi
    if [[ -n "$PF_LOG" ]]; then
        rm -f "$PF_LOG"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Checking kubectl context for HELMFILE_ENV=$HELMFILE_ENV..." >&2
make -C "$REPO_ROOT" --no-print-directory \
    "HELMFILE_ENV=$HELMFILE_ENV" "NAMESPACE=$NAMESPACE" check-kubectl-context >&2

if [[ -n "${KUBECONFIG:-}" ]]; then
    kubectl --kubeconfig "$KUBECONFIG" get service "$GATEWAY_SERVICE" \
        --namespace "$NAMESPACE" >/dev/null || {
            echo "ERROR: service/$GATEWAY_SERVICE not found in namespace $NAMESPACE" >&2
            exit 1
        }
else
    kubectl get service "$GATEWAY_SERVICE" --namespace "$NAMESPACE" >/dev/null || {
        echo "ERROR: service/$GATEWAY_SERVICE not found in namespace $NAMESPACE" >&2
        exit 1
    }
fi

is_gateway_forward_pid() {
    local pid="$1"
    local command_line
    command_line=$(ps -p "$pid" -o command= 2>/dev/null || true)
    [[ "$command_line" == *kubectl*port-forward*"service/$GATEWAY_SERVICE"* \
        && "$command_line" == *"$NAMESPACE"* \
        && "$command_line" == *"${LOCAL_PORT}:${GATEWAY_PORT}"* ]]
}

listener_pids=$(lsof -nP -iTCP:"$LOCAL_PORT" -sTCP:LISTEN -t 2>/dev/null | sort -u || true)
if [[ -n "$listener_pids" ]]; then
    forward_found=false
    while IFS= read -r pid; do
        if [[ -n "$pid" ]] && is_gateway_forward_pid "$pid"; then
            forward_found=true
            break
        fi
    done <<< "$listener_pids"
    if [[ "$forward_found" != true ]]; then
        echo "ERROR: local port $LOCAL_PORT is already in use by something other than the expected gateway port-forward" >&2
        echo "Set LOCAL_PORT to another free port and retry." >&2
        exit 1
    fi
    echo "Reusing existing port-forward to service/$GATEWAY_SERVICE on 127.0.0.1:$LOCAL_PORT" >&2
else
    PF_LOG=$(mktemp "${TMPDIR:-/tmp}/test-auth-port-forward.XXXXXX")
    echo "Starting port-forward service/$GATEWAY_SERVICE $LOCAL_PORT:$GATEWAY_PORT in namespace $NAMESPACE..." >&2
    if [[ -n "${KUBECONFIG:-}" ]]; then
        kubectl --kubeconfig "$KUBECONFIG" port-forward \
            --address 127.0.0.1 \
            --namespace "$NAMESPACE" \
            "service/$GATEWAY_SERVICE" \
            "${LOCAL_PORT}:${GATEWAY_PORT}" >"$PF_LOG" 2>&1 &
    else
        kubectl port-forward \
            --address 127.0.0.1 \
            --namespace "$NAMESPACE" \
            "service/$GATEWAY_SERVICE" \
            "${LOCAL_PORT}:${GATEWAY_PORT}" >"$PF_LOG" 2>&1 &
    fi
    PF_PID=$!
fi

# Wait until the gateway responds at the test endpoint. Any HTTP status proves
# the port-forward is up; the individual tests below check the expected status.
gateway_ready=false
for _ in {1..40}; do
    if status=$(curl --silent --show-error --connect-timeout 1 --max-time 3 \
        --header "Host: $GATEWAY_SERVICE" \
        --output /dev/null --write-out '%{http_code}' \
        "${BASE_URL%/}/api/hyperfleet/v1/clusters" 2>/dev/null) \
        && [[ -n "$status" && "$status" != 000 ]]; then
        gateway_ready=true
        break
    fi
    if [[ -n "$PF_PID" ]] && ! kill -0 "$PF_PID" 2>/dev/null; then
        break
    fi
    sleep 0.5
done
if [[ "$gateway_ready" != true ]]; then
    echo "ERROR: gateway did not respond at ${BASE_URL%/}/api/hyperfleet/v1/clusters" >&2
    if [[ -n "$PF_LOG" ]]; then
        cat "$PF_LOG" >&2
    fi
    exit 1
fi

request_status() {
    local authorization="${1:-}"
    local status
    if [[ -n "$authorization" ]]; then
        # Feed the header to curl over stdin so the JWT is not placed in curl's
        # process arguments.
        status=$(printf 'header = "Host: %s"\nheader = "Authorization: %s"\n' \
            "$GATEWAY_SERVICE" "$authorization" | \
            curl --silent --show-error --connect-timeout 5 --max-time 30 \
                --config - --output /dev/null --write-out '%{http_code}' \
                "${BASE_URL%/}/api/hyperfleet/v1/clusters" 2>/dev/null) || status=000
    else
        status=$(curl --silent --show-error --connect-timeout 5 --max-time 30 \
            --header "Host: $GATEWAY_SERVICE" \
            --output /dev/null --write-out '%{http_code}' \
            "${BASE_URL%/}/api/hyperfleet/v1/clusters" 2>/dev/null) || status=000
    fi
    printf '%s' "${status:-000}"
}

FAILURES=0
check_case() {
    local description="$1"
    local expected="$2"
    local authorization="${3:-}"
    local actual
    actual=$(request_status "$authorization")

    if [[ "$expected" == 200 && "$actual" == 200 ]]; then
        printf 'PASS: %-46s HTTP %s\n' "$description" "$actual"
    elif [[ "$expected" == reject && ( "$actual" == 401 || "$actual" == 403 ) ]]; then
        printf 'PASS: %-46s rejected with HTTP %s\n' "$description" "$actual"
    else
        printf 'FAIL: %-46s expected %s, got HTTP %s\n' \
            "$description" "$([[ "$expected" == reject ]] && echo '401 or 403' || echo 200)" "$actual"
        FAILURES=$((FAILURES + 1))
    fi
}

mint_human_token() {
    make -C "$REPO_ROOT" --no-print-directory \
        "AUTH_MODE=$AUTH_MODE" \
        "HELMFILE_ENV=$HELMFILE_ENV" \
        "NAMESPACE=$NAMESPACE" \
        OIDC_ISSUER_MODE=mock \
        "TENANT_MODEL=$TENANT_MODEL" \
        "TOKEN_SUBJECT=$TOKEN_SUBJECT" \
        "TOKEN_TENANT=$TOKEN_TENANT" \
        "TOKEN_SUBTENANT=$TOKEN_SUBTENANT" \
        mint-human-token
}

mint_machine_token() {
    make -C "$REPO_ROOT" --no-print-directory \
        "AUTH_MODE=$AUTH_MODE" \
        "HELMFILE_ENV=$HELMFILE_ENV" \
        "NAMESPACE=$NAMESPACE" \
        mint-machine-token
}

echo "Testing AUTH_MODE=$AUTH_MODE at ${BASE_URL%/}/api/hyperfleet/v1/clusters (namespace=$NAMESPACE)"

case "$AUTH_MODE" in
    NONE)
        check_case 'No Authorization header' 200
        ;;
    API)
        if ! human_token=$(mint_human_token); then
            echo "ERROR: failed to mint human token" >&2
            exit 1
        fi
        check_case 'Human token with Bearer scheme' 200 "Bearer $human_token"
        check_case 'Human token with ServiceAccount scheme' reject "ServiceAccount $human_token"
        check_case 'No Authorization header' reject

        if ! machine_token=$(mint_machine_token); then
            echo "ERROR: failed to mint machine token" >&2
            exit 1
        fi
        check_case 'Machine token with Bearer scheme' 200 "Bearer $machine_token"
        ;;
    EDGE|EDGE+API)
        if ! human_token=$(mint_human_token); then
            echo "ERROR: failed to mint human token" >&2
            exit 1
        fi
        check_case 'Human token with Bearer scheme' 200 "Bearer $human_token"
        check_case 'Human token with ServiceAccount scheme' reject "ServiceAccount $human_token"
        check_case 'No Authorization header' reject

        if ! machine_token=$(mint_machine_token); then
            echo "ERROR: failed to mint machine token" >&2
            exit 1
        fi
        check_case 'Machine token with Bearer scheme' reject "Bearer $machine_token"
        check_case 'Machine token with ServiceAccount scheme' 200 "ServiceAccount $machine_token"
        ;;
esac

if (( FAILURES > 0 )); then
    printf '\n%d authentication test(s) failed.\n' "$FAILURES" >&2
    exit 1
fi
echo 'All authentication tests passed.'
