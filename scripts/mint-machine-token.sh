#!/usr/bin/env bash
# Mint a short-lived projected ServiceAccount token for gateway TokenReview.
# The JWT is the only stdout output. Diagnostics are written to stderr.

set -euo pipefail

NAMESPACE="${NAMESPACE:-}"
AUTH_MODE="${AUTH_MODE:-NONE}"
HELMFILE_ENV="${HELMFILE_ENV:-}"
MACHINE_SERVICE_ACCOUNT="${MACHINE_SERVICE_ACCOUNT:-}"
MACHINE_TOKEN_AUDIENCE="${MACHINE_TOKEN_AUDIENCE:-hyperfleet-api}"
MACHINE_TOKEN_DURATION="${MACHINE_TOKEN_DURATION:-10m}"

if [[ -z "$MACHINE_SERVICE_ACCOUNT" ]]; then
    case "$HELMFILE_ENV" in
        e2e-kind|e2e-gcp) MACHINE_SERVICE_ACCOUNT="cl-maestro-hyperfleet-adapter" ;;
        *) MACHINE_SERVICE_ACCOUNT="adapter1-hyperfleet-adapter" ;;
    esac
fi

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
if [[ "$AUTH_MODE" != "EDGE" && "$AUTH_MODE" != "EDGE+API" ]]; then
    echo "ERROR: mint-machine-token requires AUTH_MODE=EDGE or EDGE+API" >&2
    exit 1
fi
if [[ ! "$MACHINE_SERVICE_ACCOUNT" =~ ^[a-z0-9]([a-z0-9-]{0,251}[a-z0-9])?$ ]]; then
    echo "ERROR: MACHINE_SERVICE_ACCOUNT must be a Kubernetes ServiceAccount name" >&2
    exit 1
fi
if [[ -z "$MACHINE_TOKEN_AUDIENCE" ]]; then
    echo "ERROR: MACHINE_TOKEN_AUDIENCE is required" >&2
    exit 1
fi
if [[ -z "$MACHINE_TOKEN_DURATION" ]]; then
    echo "ERROR: MACHINE_TOKEN_DURATION is required" >&2
    exit 1
fi

kubectl get serviceaccount "$MACHINE_SERVICE_ACCOUNT" --namespace "$NAMESPACE" >/dev/null \
    || {
        echo "ERROR: ServiceAccount $MACHINE_SERVICE_ACCOUNT does not exist in namespace $NAMESPACE" >&2
        exit 1
    }

printf 'Minting machine token: serviceAccount=%s audience=%s duration=%s\n' \
    "$MACHINE_SERVICE_ACCOUNT" "$MACHINE_TOKEN_AUDIENCE" "$MACHINE_TOKEN_DURATION" >&2

exec kubectl create token "$MACHINE_SERVICE_ACCOUNT" \
    --namespace "$NAMESPACE" \
    --audience "$MACHINE_TOKEN_AUDIENCE" \
    --duration "$MACHINE_TOKEN_DURATION"
