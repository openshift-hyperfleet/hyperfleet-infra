#!/usr/bin/env bash
# Rotate the API gateway's wristband signing key. Authorino
# signs with the first signingKeyRefs entry and publishes every entry in its
# JWKS, and the key ID is the Secret name, so each key gets a new Secret.
#
# This rotates the API gateway's key (release hyperfleet-gateway), the only
# gateway whose wristband keys this chart manages: the Desire Store's
# AuthConfigs come from elsewhere (authorino.policy: null) and its keys with
# them. The AuthConfig and the Authorino instance are looked up by the
# release's instance label, and the helmfile sync is scoped to that one
# release, so another gateway in the namespace is never re-synced with the
# API gateway's signing keys.
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
REVOKE="${REVOKE:-false}"
gateway_release=hyperfleet-gateway

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
wristband_path="{.spec.response.success.dynamicMetadata.wristband.wristband"
jwks_timeout=300
# hyperfleet-api accepts a JWT up to 30s past its exp claim.
api_leeway=30

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

case "$REVOKE" in
    true|false) ;;
    *) fail "REVOKE must be true or false (got '$REVOKE')" ;;
esac
[[ -n "$NAMESPACE" ]] || fail "NAMESPACE is required"
[[ -n "$HELMFILE_ENV" ]] || fail "HELMFILE_ENV is required"
for cmd in kubectl jq helmfile; do
    command -v "$cmd" >/dev/null 2>&1 || fail "required command not found: $cmd"
done

# Resolve the AuthConfig and the Authorino instance of the API gateway by its
# instance label, so the script does not duplicate the chart's naming.
authconfig=$(kubectl get authconfig --namespace "$NAMESPACE" \
    -l "app.kubernetes.io/instance=$gateway_release" \
    -o jsonpath='{.items[*].metadata.name}')
case "$authconfig" in
    "") fail "no AuthConfig labeled app.kubernetes.io/instance=$gateway_release in $NAMESPACE; the API gateway renders no policy, so it has no chart-managed wristband keys" ;;
    *" "*) fail "expected one AuthConfig for $gateway_release, found: $authconfig" ;;
esac
authorino_name=$(kubectl get authorino --namespace "$NAMESPACE" \
    -l "app.kubernetes.io/instance=$gateway_release" \
    -o jsonpath='{.items[0].metadata.name}')
[[ -n "$authorino_name" ]] || fail "no Authorino labeled app.kubernetes.io/instance=$gateway_release in $NAMESPACE"

read -r -a old_keys <<<"$(kubectl get authconfig "$authconfig" --namespace "$NAMESPACE" \
    -o jsonpath="${wristband_path}.signingKeyRefs[*].name}")"
(( ${#old_keys[@]} > 0 )) || fail "AuthConfig $authconfig has no wristband signing keys; deploy the gateway first"
token_duration=$(kubectl get authconfig "$authconfig" --namespace "$NAMESPACE" \
    -o jsonpath="${wristband_path}.tokenDuration}")
[[ "$token_duration" =~ ^[0-9]+$ ]] || fail "AuthConfig $authconfig has no wristband tokenDuration"

new_key="$(sed -E 's/-[0-9]{14}$//' <<<"${old_keys[0]}")-$(date -u +%Y%m%d%H%M%S)"
# An existing Secret would be adopted as the new signer instead of a fresh key.
if kubectl get secret "$new_key" --namespace "$NAMESPACE" >/dev/null 2>&1; then
    fail "Secret $new_key already exists; rerun in a second"
fi

jwks_path="/api/v1/namespaces/${NAMESPACE}/services/https:${authorino_name}-authorino-oidc:8083/proxy/${NAMESPACE}/${authconfig}/wristband/.well-known/openid-connect/certs"

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
        -l "component=gateway,name=$gateway_release" sync --set "authorino.policy.wristband.signingKeys={$*}"
}

echo "Rotating the API gateway wristband signing key: ${old_keys[*]} -> ${new_key} (REVOKE=${REVOKE})"
# The sweep deletes by label (whose value is the release name) and REVOKE=true
# never lists the old keys, so label them here. A key from before keys were
# labeled has none; a rolled-back
# AuthConfig can name a Secret that is gone.
for key in "${old_keys[@]}"; do
    [[ -z "$(kubectl get secret "$key" --namespace "$NAMESPACE" --ignore-not-found -o name)" ]] \
        || kubectl label secret "$key" --namespace "$NAMESPACE" "hyperfleet.io/wristband-signing-key=$gateway_release" --overwrite >/dev/null
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
