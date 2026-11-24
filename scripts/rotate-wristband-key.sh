#!/usr/bin/env bash
# Rotate the EDGE+API wristband signing key with gateway upgrades. Authorino
# signs with the first signingKeyRefs entry and publishes every entry in its
# JWKS, and the key ID is the Secret name, so each key gets a new Secret.
#
#   REVOKE=false: [old] -> [new,old] -> wait for old wristbands to expire -> [new]
#   REVOKE=true:  [old] -> [new]
#
# The gateway chart's hooks create the new Secret before the AuthConfig changes
# and delete the Secrets the AuthConfig no longer lists after it changed. The
# AuthConfig is the state, so a stopped run is finished by running the target
# again. A rerun issues another key. With REVOKE=true, requests with old
# wristbands can fail until a run completes.

set -euo pipefail

NAMESPACE="${NAMESPACE:-}"
HELMFILE_ENV="${HELMFILE_ENV:-}"
AUTH_MODE="${AUTH_MODE:-}"
REVOKE="${REVOKE:-false}"

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
authconfig="hyperfleet-tenant-policy"
wristband_path="{.spec.response.success.dynamicMetadata.wristband.wristband"
jwks_timeout=300
# hyperfleet-api accepts a JWT up to 30s past its exp claim.
api_leeway=30

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

[[ "$AUTH_MODE" == "EDGE+API" ]] || fail "rotate-wristband-key requires AUTH_MODE=EDGE+API (got '$AUTH_MODE')"
case "$REVOKE" in
    true|false) ;;
    *) fail "REVOKE must be true or false (got '$REVOKE')" ;;
esac
[[ -n "$NAMESPACE" ]] || fail "NAMESPACE is required"
[[ -n "$HELMFILE_ENV" ]] || fail "HELMFILE_ENV is required"
for cmd in kubectl jq helmfile; do
    command -v "$cmd" >/dev/null 2>&1 || fail "required command not found: $cmd"
done

read -r -a old_keys <<<"$(kubectl get authconfig "$authconfig" --namespace "$NAMESPACE" \
    -o jsonpath="${wristband_path}.signingKeyRefs[*].name}")"
(( ${#old_keys[@]} > 0 )) || fail "AuthConfig $authconfig has no wristband signing keys; deploy the gateway with AUTH_MODE=EDGE+API first"
token_duration=$(kubectl get authconfig "$authconfig" --namespace "$NAMESPACE" \
    -o jsonpath="${wristband_path}.tokenDuration}")
[[ "$token_duration" =~ ^[0-9]+$ ]] || fail "AuthConfig $authconfig has no wristband tokenDuration"

new_key="$(sed -E 's/-[0-9]{14}$//' <<<"${old_keys[0]}")-$(date -u +%Y%m%d%H%M%S)"
# An existing Secret would be adopted as the new signer instead of a fresh key.
if kubectl get secret "$new_key" --namespace "$NAMESPACE" >/dev/null 2>&1; then
    fail "Secret $new_key already exists; rerun in a second"
fi

jwks_path="/api/v1/namespaces/${NAMESPACE}/services/https:authorino-authorino-oidc:8083/proxy/${NAMESPACE}/${authconfig}/wristband/.well-known/openid-connect/certs"

# The AuthConfig Ready condition has no observedGeneration, so it cannot show
# that Authorino applied a change. Poll the JWKS that the API reads instead.
wait_for_jwks() {
    local want got="" deadline=$((SECONDS + jwks_timeout))
    want=$(printf '%s\n' "$@" | LC_ALL=C sort | paste -sd ' ' -)
    while (( SECONDS < deadline )); do
        got=$(kubectl get --raw "$jwks_path" 2>/dev/null \
            | jq -r '[.keys[].kid] | sort | join(" ")' 2>/dev/null) || got=""
        [[ "$got" == "$want" ]] && return
        sleep 5
    done
    fail "Authorino JWKS lists '${got}' after ${jwks_timeout}s, expected '${want}'"
}

# The arguments are the signing keys, signer first.
gateway_sync() {
    local IFS=,
    helmfile -f "$REPO_ROOT/helmfile/helmfile.yaml.gotmpl" -e "$HELMFILE_ENV" \
        -l component=gateway sync --set "authorino.policy.wristband.signingKeys={$*}"
}

echo "Rotating wristband signing key ${old_keys[*]} -> ${new_key} (REVOKE=${REVOKE})"
# The sweep deletes by label (whose value is the release name) and REVOKE=true
# never lists the old keys, so label them here. A key from before keys were
# labeled has none; a rolled-back
# AuthConfig can name a Secret that is gone.
for key in "${old_keys[@]}"; do
    [[ -z "$(kubectl get secret "$key" --namespace "$NAMESPACE" --ignore-not-found -o name)" ]] \
        || kubectl label secret "$key" --namespace "$NAMESPACE" hyperfleet.io/wristband-signing-key=hyperfleet-gateway --overwrite >/dev/null
done
if [[ "$REVOKE" == "false" ]]; then
    gateway_sync "$new_key" "${old_keys[@]}"
    wait_for_jwks "$new_key" "${old_keys[@]}"
    grace=$((token_duration + api_leeway))
    echo "Signing with ${new_key}. Waiting ${grace}s for wristbands signed by ${old_keys[*]} to expire..."
    sleep "$grace"
fi
gateway_sync "$new_key"
wait_for_jwks "$new_key"
echo "OK: wristband signing key rotated to ${new_key}"
