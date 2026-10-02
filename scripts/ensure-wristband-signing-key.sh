#!/usr/bin/env bash

set -euo pipefail

AUTH_MODE="${AUTH_MODE:-NONE}"
NAMESPACE="${NAMESPACE:-}"
SECRET_NAME="hyperfleet-wristband-signing-key"
PKCS1_HEADER='-----BEGIN RSA PRIVATE KEY-----'

# HYPERFLEET-1523 owns signing-key rotation. This helper deliberately creates
# the key only when absent and otherwise preserves the existing Secret.

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: required command not found: $1" >&2
        exit 1
    }
}

decode_base64() {
    base64 --decode 2>/dev/null || base64 -D 2>/dev/null
}

if [[ "$AUTH_MODE" != EDGE+API ]]; then
    echo "[NOTE: Skipping wristband signing key (AUTH_MODE=$AUTH_MODE)]"
    exit 0
fi

[[ -n "$NAMESPACE" ]] || {
    echo 'ERROR: NAMESPACE is required for AUTH_MODE=EDGE+API' >&2
    exit 1
}
require_command kubectl
require_command openssl

if kubectl get secret "$SECRET_NAME" --namespace "$NAMESPACE" >/dev/null 2>&1; then
    key=$(kubectl get secret "$SECRET_NAME" --namespace "$NAMESPACE" \
        -o 'jsonpath={.data.key\.pem}')
    [[ -n "$key" ]] || {
        echo "ERROR: existing Secret $SECRET_NAME does not contain key.pem; it was not modified" >&2
        exit 1
    }
    header=$(printf '%s' "$key" | decode_base64 | head -n 1)
    [[ "$header" == "$PKCS1_HEADER" ]] || {
        echo "ERROR: existing Secret $SECRET_NAME does not contain a PKCS#1 RSA private key; delete and recreate it with: kubectl delete secret $SECRET_NAME --namespace $NAMESPACE" >&2
        exit 1
    }
    echo "OK: preserving existing wristband signing Secret $SECRET_NAME"
    exit 0
fi

key_file=$(mktemp) || {
    echo 'ERROR: failed to create a temporary wristband signing key file' >&2
    exit 1
}
cleanup() {
    rm -f "$key_file"
}
trap cleanup EXIT HUP INT TERM

if ! openssl genrsa -traditional -out "$key_file" 3072 >/dev/null 2>&1; then
    echo 'ERROR: failed to generate an RSA PKCS#1 wristband signing key' >&2
    exit 1
fi
[[ $(head -n 1 "$key_file") == "$PKCS1_HEADER" ]] || {
    echo 'ERROR: generated wristband signing key is not a PKCS#1 RSA private key' >&2
    exit 1
}
chmod 0600 "$key_file" || {
    echo 'ERROR: failed to secure the temporary wristband signing key file' >&2
    exit 1
}
if ! kubectl create secret generic "$SECRET_NAME" --namespace "$NAMESPACE" --from-file=key.pem="$key_file"; then
    echo "ERROR: failed to create Secret $SECRET_NAME" >&2
    exit 1
fi

echo "OK: created wristband signing Secret $SECRET_NAME"
