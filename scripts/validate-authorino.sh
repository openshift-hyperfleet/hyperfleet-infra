#!/usr/bin/env bash

set -euo pipefail

HELM_DIR="${HELM_DIR:-helm}"
GATEWAY_CHART="$HELM_DIR/hyperfleet-gateway"

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: required command not found: $1" >&2
        exit 1
    }
}

require_command helm
require_command openssl

# Authorino v0.26.2 expects the legacy RSA PEM encoding for wristband keys.
# OpenSSL 3 defaults to PKCS#8, so exercise the exact command used by Makefile.
validate_wristband_signing_key_format() {
    local key_file
    key_file=$(mktemp)

    if ! openssl genrsa -traditional -out "$key_file" 3072 >/dev/null 2>&1; then
        echo 'ERROR: unable to generate a traditional PKCS#1 RSA wristband signing key' >&2
        rm -f "$key_file"
        exit 1
    fi
    if [[ $(head -n 1 "$key_file") != '-----BEGIN RSA PRIVATE KEY-----' ]]; then
        echo 'ERROR: pinned Authorino wristband configuration requires a PKCS#1 RSA private key' >&2
        rm -f "$key_file"
        exit 1
    fi
    rm -f "$key_file"
}

render_gateway() {
    helm template gw "$GATEWAY_CHART" --namespace default \
        --set-string "auth.mode=$1" \
        --set-string 'auth.identityProviders[0].name=human' \
        --set-string 'auth.identityProviders[0].issuerUrl=https://issuer.invalid/oidc' \
        --set-string 'auth.identityProviders[0].audience=hyperfleet-api' 2>&1
}

assert_contains() {
    local output=$1 pattern=$2 message=$3
    grep -q -- "$pattern" <<<"$output" || {
        echo "ERROR: $message" >&2
        exit 1
    }
}

assert_not_contains() {
    local output=$1 pattern=$2 message=$3
    ! grep -q -- "$pattern" <<<"$output" || {
        echo "ERROR: $message" >&2
        exit 1
    }
}

assert_filter_order() {
    local output=$1 message=$2 first=$3 second=$4 third=${5:-}
    awk -v first="$first" -v second="$second" -v third="$third" '
        index($0, first) { first_line = NR }
        index($0, second) { second_line = NR }
        third != "" && index($0, third) { third_line = NR }
        END {
            if (third == "") {
                exit !(first_line > 0 && second_line > first_line)
            }
            exit !(first_line > 0 && second_line > first_line && third_line > second_line)
        }
    ' <<<"$output" || {
        echo "ERROR: $message" >&2
        exit 1
    }
}

assert_machine_allow_list() {
    local output=$1 model=$2 subject_pattern
    subject_pattern=$(sed -n 's/^[[:space:]]*value: "\(\^system:serviceaccount:[^"]*\)"$/\1/p' <<<"$output")
    [[ -n "$subject_pattern" ]] || {
        echo "ERROR ($model): machine ServiceAccount allow-list pattern not rendered" >&2
        exit 1
    }

    for service_account in \
        clusters-hyperfleet-sentinel \
        nodepools-hyperfleet-sentinel \
        adapter1-hyperfleet-adapter \
        adapter2-hyperfleet-adapter \
        adapter3-hyperfleet-adapter; do
        printf 'system:serviceaccount:default:%s\n' "$service_account" | grep -Eq "$subject_pattern" || {
            echo "ERROR ($model): allow-list rejects known ServiceAccount $service_account" >&2
            exit 1
        }
    done

    for service_account in default hyperfleet-api hyperfleet-adapter-lookalike unrelated; do
        if printf 'system:serviceaccount:default:%s\n' "$service_account" | grep -Eq "$subject_pattern"; then
            echo "ERROR ($model): allow-list accepts unlisted ServiceAccount $service_account" >&2
            exit 1
        fi
    done
}

echo "Validating HyperFleet gateway security templates..."
validate_wristband_signing_key_format

for mode in NONE EDGE API EDGE+API; do
    if ! out=$(render_gateway "$mode"); then
        echo "ERROR: render failed for AUTH_MODE=$mode" >&2
        echo "$out" >&2
        exit 1
    fi

    expected_certificates=2
    case "$mode" in
        EDGE|EDGE+API) expected_certificates=4 ;;
    esac

    certificate_count=$(grep -c '^kind: Certificate$' <<<"$out" || true)
    [[ "$certificate_count" -eq "$expected_certificates" ]] || {
        echo "ERROR ($mode): unexpected number of internal TLS Certificates" >&2
        exit 1
    }
    assert_not_contains "$out" 'DownstreamTlsContext' \
        "($mode): gateway listener must remain HTTP"
    assert_contains "$out" 'exact: hyperfleet-api.default.svc' \
        "($mode): API certificate SAN validation missing"
    assert_contains "$out" 'filename: /etc/envoy/tls/ca.crt' \
        "($mode): shared CA trust missing"
    assert_contains "$out" 'kind: Job' \
        "($mode): certificate readiness hook missing"
    assert_contains "$out" 'kubectl wait --for=condition=Ready certificate/hyperfleet-api' \
        "($mode): API certificate readiness wait missing"
    assert_contains "$out" 'kubectl wait --for=condition=Ready certificate/gw-hyperfleet-gateway-ca' \
        "($mode): gateway CA readiness wait missing"

    case "$mode" in
        EDGE|EDGE+API)
            assert_contains "$out" '^kind: Authorino$' "($mode): Authorino missing"
            assert_contains "$out" 'image: "quay.io/kuadrant/authorino:v0.26.2"' \
                "($mode): expected pinned Authorino image is missing"
            assert_contains "$out" 'failure_mode_allow: false' \
                "($mode): ext_authz is not fail-closed"
            assert_contains "$out" 'kubernetesTokenReview:' \
                "($mode): TokenReview missing"
            assert_contains "$out" 'kubectl wait --for=condition=Ready certificate/authorino-authorino-authorization' \
                "($mode): Authorino authorization certificate readiness wait missing"
            assert_contains "$out" 'kubectl wait --for=condition=Ready certificate/authorino-authorino-oidc' \
                "($mode): Authorino OIDC certificate readiness wait missing"
            assert_machine_allow_list "$out" "$mode"
            assert_contains "$out" 'type(auth.identity.aud) == string' \
                "($mode): human JWT audience rule does not support string claims"
            assert_contains "$out" ' in auth.identity.aud' \
                "($mode): human JWT audience rule does not support array claims"
            assert_filter_order "$out" \
                "($mode): ext_authz must precede router" \
                'name: envoy.filters.http.ext_authz' \
                'name: envoy.filters.http.router'
            ;;
        *)
            assert_not_contains "$out" '^kind: Authorino$' \
                "($mode): Authorino unexpectedly rendered"
            assert_not_contains "$out" 'name: envoy.filters.http.ext_authz' \
                "($mode): ext_authz unexpectedly rendered"
            ;;
    esac

    if [[ "$mode" == EDGE+API ]]; then
        assert_contains "$out" 'algorithm: RS256' 'RS256 wristband missing'
        assert_contains "$out" 'dynamicMetadata' 'wristband dynamic metadata missing'
        assert_filter_order "$out" \
            'wristband Lua filter must be between ext_authz and router' \
            'name: envoy.filters.http.ext_authz' \
            'name: envoy.filters.http.lua' \
            'name: envoy.filters.http.router'
    else
        assert_not_contains "$out" 'name: envoy.filters.http.lua' \
            "($mode): wristband Lua unexpectedly rendered"
    fi
done

if helm template gw "$GATEWAY_CHART" --set-string auth.mode=INVALID >/dev/null 2>&1; then
    echo "ERROR: invalid AUTH_MODE was accepted" >&2
    exit 1
fi

for model in onprem oracle; do
    if ! out=$(helm template gw "$GATEWAY_CHART" \
        --set-string auth.mode=EDGE \
        --set "tenant.model=$model" \
        --set-string 'auth.identityProviders[0].name=human' \
        --set-string 'auth.identityProviders[0].issuerUrl=https://issuer.invalid/oidc' \
        --set-string 'auth.identityProviders[0].audience=hyperfleet-api'); then
        echo "ERROR: render failed for tenant model $model" >&2
        exit 1
    fi

    assert_filter_order "$out" \
        "($model): x-hyperfleet-identity must retain its email mapping" \
        'x-hyperfleet-identity:' \
        'selector: auth.identity.email'

    case "$model" in
        onprem)
            optional_header=x-tenant-project
            optional_claim=project_id
            ;;
        oracle)
            optional_header=x-tenant-compartment
            optional_claim=compartment_id
            ;;
    esac

    awk -v header="$optional_header" -v claim="$optional_claim" '
        index($0, sprintf("%c%s%c:", 34, header, 34)) > 0 || index($0, header ":") > 0 { found_header = 1 }
        found_header && /when:/ { found_when = 1 }
        found_header && $0 ~ "selector: auth.identity." claim { found_claim = 1 }
        END { exit !(found_header && found_when && found_claim) }
    ' <<<"$out" || {
        echo "ERROR ($model): optional tenant header is not when-gated" >&2
        exit 1
    }
done

if helm template gw "$GATEWAY_CHART" \
    --set-string auth.mode=EDGE \
    --set tenant.model=bogus \
    --set-string 'auth.identityProviders[0].name=human' \
    --set-string 'auth.identityProviders[0].issuerUrl=https://issuer.invalid/oidc' \
    --set-string 'auth.identityProviders[0].audience=hyperfleet-api' >/dev/null 2>&1; then
    echo "ERROR: invalid tenant model was accepted" >&2
    exit 1
fi

if ! hosts_out=$(helm template gw "$GATEWAY_CHART" \
    --set-string auth.mode=EDGE \
    --set-string 'auth.identityProviders[0].name=human' \
    --set-string 'auth.identityProviders[0].issuerUrl=https://issuer.invalid/oidc' \
    --set-string 'auth.identityProviders[0].audience=hyperfleet-api' \
    --set auth.authorino.hosts='{gateway.example.com}'); then
    echo "ERROR: render failed with authorino.hosts set" >&2
    exit 1
fi

assert_contains "$hosts_out" '"gw-hyperfleet-gateway"' \
    'default gateway Service host dropped when authorino.hosts is set'
assert_contains "$hosts_out" '"localhost"' \
    'default localhost host dropped when authorino.hosts is set'
assert_contains "$hosts_out" '"gateway.example.com"' \
    'configured authorino.hosts entry not rendered'

echo "OK: gateway internal TLS, Authorino, and AUTH_MODE templates valid"
