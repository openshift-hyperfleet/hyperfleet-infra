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

# render_gateway MODE [HELM ARGS]
# MODE is the ADR-0034 mode the chart's values stand for: NONE and API deploy no
# Authorino (API only changes the API chart), EDGE deploys it, EDGE+API also
# enables the wristband.
render_gateway() {
    local mode_args=()
    case "$1" in
        NONE | API) ;;
        EDGE) mode_args=(--set authorino.enabled=true) ;;
        EDGE+API) mode_args=(--set authorino.enabled=true --set authorino.policy.wristband.enabled=true) ;;
        *) echo "ERROR: unknown mode $1" >&2; exit 1 ;;
    esac
    helm template gw "$GATEWAY_CHART" --namespace default \
        "${mode_args[@]}" \
        --set-string 'authorino.policy.identityProviders[0].name=human' \
        --set-string 'authorino.policy.identityProviders[0].issuerUrl=https://issuer.invalid/oidc' \
        --set-string 'authorino.policy.identityProviders[0].audience=hyperfleet-api' \
        --set-string 'authorino.policy.identityProviders[1].name=partner' \
        --set-string 'authorino.policy.identityProviders[1].issuerUrl=https://partner-issuer.invalid/oidc' \
        --set-string 'authorino.policy.identityProviders[1].audience=hyperfleet-partner-api' "${@:2}" 2>&1
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

assert_jwt_claim_enforcement() {
    local output=$1 provider=$2 issuer=$3 audience=$4 provider_block
    provider_block=$(awk -v provider="$provider" '
        $0 == "    \"" provider "\":" { capture = 1; next }
        capture && /^    "/ { exit }
        capture { print }
    ' <<<"$output")

    [[ -n "$provider_block" ]] || {
        echo "ERROR: JWT provider $provider was not rendered" >&2
        exit 1
    }
    assert_contains "$provider_block" "issuerUrl: \"$issuer\"" \
        "JWT provider $provider has the wrong discovery issuerUrl"
    assert_contains "$provider_block" "issuer: \"$issuer\"" \
        "JWT provider $provider does not enforce its issuer during authentication"
    assert_contains "$provider_block" 'audiences:' \
        "JWT provider $provider does not enforce an audience during authentication"
    assert_contains "$provider_block" "- \"$audience\"" \
        "JWT provider $provider has the wrong enforced audience"
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

# The rendered YAML document of one kind.
rendered_document() {
    awk -v kind="$2" '/^---$/ { doc++ } { docs[doc] = docs[doc] $0 "\n" }
        END { for (i in docs) if (docs[i] ~ ("(^|\n)kind: " kind "\n")) printf "%s", docs[i] }' <<<"$1"
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

# assert_listener_ref DOCUMENT KEY GATEWAY LISTENER MESSAGE
# Passes when one item under KEY (targetRefs or parentRefs) in DOCUMENT is a
# `kind: Gateway` reference to GATEWAY with sectionName LISTENER. An empty LISTENER
# only checks the kind and the name.
assert_listener_ref() {
    local document=$1 key=$2 gateway=$3 listener=$4 message=$5
    awk -v key="$key" -v gateway="$gateway" -v listener="$listener" '
        function check() {
            if (item ~ /[ -]kind: Gateway\n/ && item ~ ("[ -]name: " gateway "\n") \
                && (listener == "" || item ~ ("[ -]sectionName: " listener "\n"))) {
                found = 1
            }
        }
        $0 ~ ("^  " key ":$") { inrefs = 1; next }
        inrefs && /^  [A-Za-z]/ { inrefs = 0 }
        inrefs && /^    - / { if (item != "") check(); item = $0 "\n"; next }
        inrefs { item = item $0 "\n" }
        END { if (item != "") check(); exit !found }
    ' <<<"$document" || {
        echo "ERROR: $message" >&2
        exit 1
    }
}

# The headers listed under earlyRequestHeaders.remove in a ClientTrafficPolicy.
stripped_headers() {
    awk '/^      remove:$/ { inlist = 1; next }
        inlist && /^        - / { sub(/^        - /, ""); print; next }
        inlist { exit }' <<<"$1"
}

echo "Validating HyperFleet gateway security templates..."

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
    assert_not_contains "$out" 'protocol: HTTPS' \
        "($mode): gateway listener must remain HTTP"
    for kind in EnvoyProxy Gateway HTTPRoute ClientTrafficPolicy BackendTLSPolicy BackendTrafficPolicy; do
        assert_contains "$out" "^kind: $kind\$" \
            "($mode): $kind missing"
    done
    assert_contains "$out" 'hostname: hyperfleet-api.default.svc' \
        "($mode): API certificate SAN validation missing"
    assert_contains "$out" 'name: gw-hyperfleet-gateway-ca-cert' \
        "($mode): shared CA trust missing"
    gateway_name=gw-hyperfleet-gateway
    route_doc=$(rendered_document "$out" HTTPRoute)
    assert_listener_ref "$route_doc" parentRefs "$gateway_name" http \
        "($mode): the HTTPRoute must attach to the serving listener of the Gateway"
    assert_contains "$route_doc" '^        - name: hyperfleet-api$' \
        "($mode): the HTTPRoute does not send traffic to the upstream"
    # Client-supplied identity headers are removed before authorization runs. The
    # check reads the ClientTrafficPolicy's own remove list, not the whole output.
    strip_policy=$(rendered_document "$out" ClientTrafficPolicy)
    assert_listener_ref "$strip_policy" targetRefs "$gateway_name" "" \
        "($mode): the ClientTrafficPolicy must target the Gateway"
    removed_headers=$(stripped_headers "$strip_policy")
    for header in x-tenant-org x-tenant-project x-tenant-tenancy-ocid x-tenant-compartment \
        x-hyperfleet-system x-hyperfleet-identity; do
        grep -qx -- "$header" <<<"$removed_headers" || {
            echo "ERROR: ($mode): $header is not in the ClientTrafficPolicy remove list" >&2
            exit 1
        }
    done
    assert_not_contains "$strip_policy" '^      \(add\|set\|addIfAbsent\|removeOnMatch\):' \
        "($mode): the ClientTrafficPolicy must only remove headers"
    assert_contains "$out" 'kind: Job' \
        "($mode): certificate readiness hook missing"
    assert_contains "$out" 'kubectl wait --for=condition=Ready certificate/hyperfleet-api' \
        "($mode): API certificate readiness wait missing"
    assert_contains "$out" 'kubectl wait --for=condition=Ready certificate/gw-hyperfleet-gateway-ca' \
        "($mode): gateway CA readiness wait missing"

    case "$mode" in
        EDGE|EDGE+API)
            assert_contains "$out" '^kind: Authorino$' "($mode): Authorino missing"
            assert_contains "$out" 'image: "quay.io/kuadrant/authorino:v0.28.0"' \
                "($mode): expected pinned Authorino image is missing"
            assert_contains "$out" '^kind: SecurityPolicy$' \
                "($mode): SecurityPolicy missing"
            security_policy=$(rendered_document "$out" SecurityPolicy)
            assert_contains "$security_policy" '^    failOpen: false$' \
                "($mode): ext_authz is not fail-closed"
            assert_contains "$security_policy" '^    timeout: 1s$' \
                "($mode): ext_authz has no 1s timeout"
            assert_contains "$security_policy" '^        - name: authorino-authorino-authorization$' \
                "($mode): ext_authz does not target the Authorino authorization Service"
            assert_contains "$security_policy" '^          port: 50051$' \
                "($mode): ext_authz does not use Authorino's gRPC port"
            assert_contains "$out" 'kubernetesTokenReview:' \
                "($mode): TokenReview missing"
            assert_contains "$out" 'kubectl wait --for=condition=Ready certificate/authorino-authorino-authorization' \
                "($mode): Authorino authorization certificate readiness wait missing"
            assert_contains "$out" 'kubectl wait --for=condition=Ready certificate/authorino-authorino-oidc' \
                "($mode): Authorino OIDC certificate readiness wait missing"
            assert_machine_allow_list "$out" "$mode"
            assert_jwt_claim_enforcement "$out" human \
                'https://issuer.invalid/oidc' hyperfleet-api
            assert_jwt_claim_enforcement "$out" partner \
                'https://partner-issuer.invalid/oidc' hyperfleet-partner-api
            # The policy must attach to the serving listener of the Gateway, not one
            # route, so a route added there without a policy of its own is still
            # authenticated.
            assert_listener_ref "$security_policy" targetRefs "$gateway_name" http \
                "($mode): the SecurityPolicy must target the serving listener of the Gateway"
            ;;
        *)
            assert_not_contains "$out" '^kind: Authorino$' \
                "($mode): Authorino unexpectedly rendered"
            assert_not_contains "$out" '^kind: SecurityPolicy$' \
                "($mode): SecurityPolicy unexpectedly rendered"
            assert_not_contains "$out" 'authorino-authorization' \
                "($mode): Authorino unexpectedly referenced"
            ;;
    esac

    if [[ "$mode" == EDGE+API ]]; then
        assert_contains "$out" 'algorithm: RS256' 'RS256 wristband missing'
        assert_contains "$out" 'dynamicMetadata' 'wristband dynamic metadata missing'
        assert_contains "$out" 'name: gw-hyperfleet-gateway-wristband-key-provisioner' \
            'EDGE+API: signing-key provisioner hook missing'
        assert_contains "$out" '"helm.sh/hook": "pre-install,pre-upgrade"' \
            'EDGE+API: signing-key provisioner must run before AuthConfig creation'
        assert_contains "$out" 'bitnami/kubectl:1.33.4-debian-12-r0@sha256:ed0b31a0508da84ee655c5c6e01bd3897fc56ad6cf69debb27fa1893a06d2246' \
            'EDGE+API: immutable Bitnami Debian 12 kubectl image missing'
        assert_contains "$out" "openssl genrsa -traditional -out \"\${key_file}\" 3072" \
            'EDGE+API: provisioner does not generate a 3072-bit PKCS#1 RSA key'
        assert_contains "$out" 'does not contain a 3072-bit RSA private key' \
            'EDGE+API: provisioner does not validate an existing key size'
        assert_contains "$out" 'resourceNames:' \
            'EDGE+API: signing-key Role lacks named-Secret restrictions'
        assert_contains "$out" 'name: gw-hyperfleet-gateway-wristband-key-cleanup' \
            'EDGE+API: uninstall signing-key cleanup hook missing'
        assert_not_contains "$out" '"helm.sh/hook": "post-install,post-upgrade,pre-delete"' \
            'EDGE+API: cleanup must not delete a still-required signing key during upgrade'
        assert_contains "$out" "kubectl label secret \"\${secret_name}\" hyperfleet.io/wristband-signing-key=gw --overwrite" \
            'EDGE+API: provisioner must label an existing signing key it keeps'
        assert_contains "$out" 'kubectl label --local -f - hyperfleet.io/wristband-signing-key=gw' \
            'EDGE+API: provisioner must label a new signing key when it creates it'
        assert_contains "$out" '^kind: EnvoyExtensionPolicy$' \
            'EDGE+API: wristband Lua policy missing'
        # Envoy Gateway keeps the ext_authz metadata under the plain namespace, so
        # that is the only lookup: a second key would be dead code.
        assert_contains "$out" 'dynamicMetadata():get("envoy.filters.http.ext_authz")' \
            'EDGE+API: wristband Lua does not read the ext_authz metadata'
        assert_not_contains "$out" 'ext_authz/securitypolicy' \
            'EDGE+API: wristband Lua looks up a per-policy metadata namespace'
    else
        assert_not_contains "$out" '^kind: EnvoyExtensionPolicy$' \
            "($mode): wristband Lua unexpectedly rendered"
        assert_not_contains "$out" 'wristband-key-provisioner' \
            "($mode): wristband provisioner unexpectedly rendered"
        assert_not_contains "$out" 'name: gw-hyperfleet-gateway-wristband-key-' \
            "($mode): wristband key Jobs unexpectedly rendered without labeled keys"
    fi
done

# helm template has no cluster, so lookup finds no live AuthConfig and no
# labeled keys: the cleanup sweep and the AuthConfig fallback need a cluster,
# and make check-wristband-rotation covers them.
old_key=hyperfleet-wristband-signing-key
new_key=hyperfleet-wristband-signing-key-20990101000000
if ! out=$(render_gateway EDGE+API --set "authorino.policy.wristband.signingKeys={$new_key,$old_key}"); then
    echo "ERROR: render failed with wristband signing keys" >&2
    echo "$out" >&2
    exit 1
fi
signing_key_refs=$(awk '/signingKeyRefs:/ { refs = 1; next }
    refs && /- name:/ { print $3 }
    refs && /customClaims:/ { exit }' <<<"$out" | paste -sd ' ' -)
[[ "$signing_key_refs" == "\"$new_key\" \"$old_key\"" ]] || {
    echo "ERROR: EDGE+API: signingKeyRefs is [$signing_key_refs], expected [\"$new_key\" \"$old_key\"]" >&2
    exit 1
}
assert_contains "$out" "signer=\"$new_key\"" \
    'EDGE+API: provisioner must create the new wristband key'
assert_contains "$out" "resourceNames: \[\"$new_key\",\"$old_key\"\]" \
    'EDGE+API: signing-key RBAC must name both wristband keys'
if render_gateway EDGE+API --set 'authorino.policy.wristband.signingKeys={Bad_Key}' >/dev/null 2>&1; then
    echo "ERROR: invalid wristband signing key name was accepted" >&2
    exit 1
fi

# The mode is derived from authorino.enabled and the wristband flag, so the old
# authorino.mode key must be rejected, not ignored.
if helm template gw "$GATEWAY_CHART" --set-string authorino.mode=EDGE >/dev/null 2>&1; then
    echo "ERROR: the removed authorino.mode key was accepted" >&2
    exit 1
fi
if helm template gw "$GATEWAY_CHART" --set authorino.enabled=maybe >/dev/null 2>&1; then
    echo "ERROR: a non-boolean authorino.enabled was accepted" >&2
    exit 1
fi

for model in onprem oracle; do
    if ! out=$(helm template gw "$GATEWAY_CHART" \
        --set authorino.enabled=true \
        --set "authorino.policy.tenant.model=$model" \
        --set-string 'authorino.policy.identityProviders[0].name=human' \
        --set-string 'authorino.policy.identityProviders[0].issuerUrl=https://issuer.invalid/oidc' \
        --set-string 'authorino.policy.identityProviders[0].audience=hyperfleet-api'); then
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
    --set authorino.enabled=true \
    --set authorino.policy.tenant.model=bogus \
    --set-string 'authorino.policy.identityProviders[0].name=human' \
    --set-string 'authorino.policy.identityProviders[0].issuerUrl=https://issuer.invalid/oidc' \
    --set-string 'authorino.policy.identityProviders[0].audience=hyperfleet-api' >/dev/null 2>&1; then
    echo "ERROR: invalid tenant model was accepted" >&2
    exit 1
fi

if ! hosts_out=$(helm template gw "$GATEWAY_CHART" \
    --set authorino.enabled=true \
    --set-string 'authorino.policy.identityProviders[0].name=human' \
    --set-string 'authorino.policy.identityProviders[0].issuerUrl=https://issuer.invalid/oidc' \
    --set-string 'authorino.policy.identityProviders[0].audience=hyperfleet-api' \
    --set authorino.hosts='{gateway.example.com}'); then
    echo "ERROR: render failed with authorino.hosts set" >&2
    exit 1
fi

assert_contains "$hosts_out" '"gw-hyperfleet-gateway"' \
    'default gateway Service host dropped when authorino.hosts is set'
assert_contains "$hosts_out" '"localhost"' \
    'default localhost host dropped when authorino.hosts is set'
assert_contains "$hosts_out" '"gateway.example.com"' \
    'configured authorino.hosts entry not rendered'

# A second gateway (the Desire Store) is a second release of this chart in the
# same namespace: nothing it renders may collide with the first release, and
# nothing it renders is cluster-scoped, so abandoned runs leave nothing behind.
rendered_objects() {
    awk '/^---$/ { kind = ""; named = 0 }
        /^kind: / { kind = $2 }
        kind != "" && !named && /^  name: / { print kind "/" $2; named = 1 }'
}

# No policy: the AuthConfigs of this gateway come from elsewhere (an operator).
second_gateway_args=(
    --set authorino.enabled=true
    --set-string fullnameOverride=desire-store-gateway
    --set-string upstream.host=desire-store-api
    --set-string authorino.name=authorino-ds
    --set-string authorino.authConfigLabelSelectors=hyperfleet.io/desire-store
    --set authorino.policy=null
)
if ! first_out=$(render_gateway EDGE --namespace default); then
    echo "ERROR: render failed for the first gateway release" >&2
    echo "$first_out" >&2
    exit 1
fi
if ! second_out=$(helm template ds "$GATEWAY_CHART" --namespace default \
    "${second_gateway_args[@]}" 2>&1); then
    echo "ERROR: render failed for a second gateway release" >&2
    echo "$second_out" >&2
    exit 1
fi
collisions=$(comm -12 <(rendered_objects <<<"$first_out" | sort) <(rendered_objects <<<"$second_out" | sort))
[[ -z "$collisions" ]] || {
    echo "ERROR: two gateway releases render the same objects:" >&2
    echo "$collisions" >&2
    exit 1
}
assert_not_contains "$second_out" '^kind: AuthConfig$' \
    'second gateway: AuthConfig rendered although authorino.policy is null'
assert_contains "$second_out" 'authConfigLabelSelectors: "hyperfleet.io/desire-store"' \
    'second gateway: Authorino shard selector missing'
assert_contains "$(rendered_document "$second_out" Gateway)" '^  name: desire-store-gateway$' \
    'second gateway: the Gateway is not named after its release'
for out in "$first_out" "$second_out"; do
    assert_not_contains "$out" '^kind: \(ClusterRole\|ClusterRoleBinding\|Namespace\|GatewayClass\)$' \
        'a gateway release renders a cluster-scoped object'
done

# The GatewayClass is shared and cluster-scoped, so the chart does not render it:
# make install-envoy-gateway applies it from manifests/. The Gateway refers to it by
# the gatewayClassName value, whose default must name the class in that manifest.
manifests_dir="${MANIFESTS_DIR:-manifests}"
class_manifest="$manifests_dir/envoy-gateway-gatewayclass.yaml"
shared_class=$(sed -n 's/^  name: //p' "$class_manifest")
[[ -n "$shared_class" ]] || {
    echo "ERROR: $class_manifest does not name a GatewayClass" >&2
    exit 1
}
assert_contains "$(cat "$class_manifest")" '^kind: GatewayClass$' "$class_manifest is not a GatewayClass"
assert_contains "$(cat "$class_manifest")" '^  controllerName: gateway.envoyproxy.io/gatewayclass-controller$' \
    "$class_manifest does not name the Envoy Gateway controller"
for out in "$first_out" "$second_out"; do
    assert_not_contains "$out" '^kind: GatewayClass$' 'the chart renders a GatewayClass'
    assert_contains "$(rendered_document "$out" Gateway)" "^  gatewayClassName: $shared_class\$" \
        'the Gateway does not use the shared GatewayClass'
done
class_out=$(render_gateway NONE --set-string gatewayClassName=custom-class)
assert_contains "$(rendered_document "$class_out" Gateway)" '^  gatewayClassName: custom-class$' \
    'gatewayClassName is ignored'

# Names at their length limit. A fullname may have 63 characters, and a suffix
# appended to it must never merge two objects.
long_fullname=$(printf 'a%.0s' {1..63})
if ! long_out=$(render_gateway EDGE --set-string "fullnameOverride=$long_fullname"); then
    echo "ERROR: render failed with a 63-character fullname" >&2
    echo "$long_out" >&2
    exit 1
fi
for kind in BackendTLSPolicy BackendTrafficPolicy; do
    names=$(rendered_objects <<<"$long_out" | sed -n "s|^$kind/||p")
    [[ "$(wc -l <<<"$names")" -eq 2 && "$(sort -u <<<"$names" | wc -l)" -eq 2 ]] || {
        echo "ERROR: a 63-character fullname collapses the $kind names into one: $(paste -sd' ' <<<"$names")" >&2
        exit 1
    }
done

# The PodDisruptionBudget and the proxy hardening are fixed in the template.
envoyproxy_doc=$(rendered_document "$first_out" EnvoyProxy)
assert_contains "$envoyproxy_doc" '^        maxUnavailable: 1$' 'the PodDisruptionBudget is not fixed at maxUnavailable 1'
assert_contains "$envoyproxy_doc" 'readOnlyRootFilesystem: true' 'the proxy container is not hardened'
assert_contains "$envoyproxy_doc" 'runAsNonRoot: true' 'the proxy pod is not hardened'

# Certificate Secret names follow the upstream host and the Authorino name, so a
# second gateway gets its own without any setting.
assert_contains "$first_out" 'secretName: authorino-server-cert' 'Authorino authorization Secret name'
assert_contains "$first_out" 'secretName: authorino-oidc-server-cert' 'Authorino OIDC Secret name'
assert_contains "$first_out" 'secretName: hyperfleet-api-server-cert' 'upstream serving Secret name'
assert_contains "$second_out" 'secretName: authorino-ds-server-cert' 'second gateway: Authorino authorization Secret name'
assert_contains "$second_out" 'secretName: authorino-ds-oidc-server-cert' 'second gateway: Authorino OIDC Secret name'
assert_contains "$second_out" 'secretName: desire-store-api-server-cert' 'second gateway: upstream serving Secret name'
override_out=$(render_gateway NONE --set-string upstream.tlsSecretName=custom-upstream-cert)
assert_contains "$override_out" 'secretName: custom-upstream-cert' 'upstream.tlsSecretName is ignored'

# Listeners: the route, the SecurityPolicy and the Lua policy attach to every
# listener except one marked authenticated: false (the ACME solver, 1912).
listeners='gateway.listeners=[{"name":"base","port":8000,"protocol":"HTTP","hostname":"ds.example.com"},{"name":"wild","port":8000,"protocol":"HTTP","hostname":"*.ds.example.com"},{"name":"acme","port":80,"protocol":"HTTP","authenticated":false}]'
if ! listeners_out=$(render_gateway EDGE+API --set-json "$listeners"); then
    echo "ERROR: render failed with three listeners" >&2
    echo "$listeners_out" >&2
    exit 1
fi
for kind_and_key in "HTTPRoute parentRefs" "SecurityPolicy targetRefs" "EnvoyExtensionPolicy targetRefs"; do
    read -r kind refs_key <<<"$kind_and_key"
    doc=$(rendered_document "$listeners_out" "$kind")
    assert_listener_ref "$doc" "$refs_key" gw-hyperfleet-gateway base \
        "$kind does not target the base listener of the Gateway"
    assert_listener_ref "$doc" "$refs_key" gw-hyperfleet-gateway wild \
        "$kind does not target the wildcard listener of the Gateway"
    assert_not_contains "$doc" 'sectionName: acme' "$kind covers the unauthenticated listener"
done
for name in base wild acme; do
    assert_contains "$(rendered_document "$listeners_out" Gateway)" "name: $name" "the Gateway lacks listener $name"
done
if render_gateway NONE --set-json 'gateway.listeners=[{"name":"acme","port":80,"protocol":"HTTP","authenticated":false}]' >/dev/null 2>&1; then
    echo "ERROR: a gateway with no authenticated listener was accepted" >&2
    exit 1
fi

# A wristband is issued by Authorino, so it cannot be enabled without it.
if render_gateway NONE --set authorino.policy.wristband.enabled=true >/dev/null 2>&1; then
    echo "ERROR: a wristband without authorino.enabled was accepted" >&2
    exit 1
fi
# A release with no policy (AuthConfigs from an operator) still renders, and its
# hooks read the image from authorino.wristbandHookImage, not from under the policy.
no_policy_out=$(helm template gw "$GATEWAY_CHART" --namespace default --set authorino.enabled=true --set authorino.policy=null 2>&1)
assert_not_contains "$no_policy_out" '^kind: AuthConfig$' 'a release with policy: null renders an AuthConfig'
assert_not_contains "$no_policy_out" 'signing-key' 'a release with policy: null renders signing-key resources'
for hook in wristband-key-cleanup wristband-key-provisioner; do
    hook_template="$GATEWAY_CHART/templates/$hook.yaml"
    grep -q '\.Values\.authorino\.wristbandHookImage' "$hook_template" \
        || { echo "ERROR: $hook does not read authorino.wristbandHookImage" >&2; exit 1; }
    ! grep -q 'authorino\.policy\.wristband\.lifecycle' "$hook_template" \
        || { echo "ERROR: $hook reads its image from under the policy" >&2; exit 1; }
done

# Only methods that are safe to repeat are retried, and the list is fixed in the
# route, not a value: a retry-method override is rejected, and the default rule
# retries nothing.
if render_gateway NONE --set-json 'traffic.retry.methods=["POST"]' >/dev/null 2>&1; then
    echo "ERROR: the removed traffic.retry.methods value was accepted" >&2
    exit 1
fi
retry_out=$(render_gateway NONE)
retry_route=$(rendered_document "$retry_out" HTTPRoute)
for method in GET HEAD PUT DELETE; do
    assert_contains "$retry_route" "^        - method: $method\$" "the idempotent rule does not match $method"
done
assert_not_contains "$retry_route" 'method: \(POST\|PATCH\)' 'the HTTPRoute matches an unsafe method'
retry_policies=$(awk '/^---$/ { n++ } { doc[n] = doc[n] $0 "\n" } END { for (i in doc) if (doc[i] ~ /kind: BackendTrafficPolicy/) printf "%s---\n", doc[i] }' <<<"$retry_out")
[[ "$(grep -c '^  retry:$' <<<"$retry_policies")" == 1 ]] || {
    echo "ERROR: exactly one BackendTrafficPolicy (the idempotent rule) must retry" >&2
    exit 1
}

# The identity and tenant headers are always stripped. headers.stripOverride only
# adds to them, so an override can never leave a trusted header forgeable.
override_out=$(render_gateway NONE --set 'headers.stripOverride={x-extra,x-hyperfleet-system}')
override_headers=$(stripped_headers "$(rendered_document "$override_out" ClientTrafficPolicy)")
for header in x-tenant-org x-tenant-project x-tenant-tenancy-ocid x-tenant-compartment \
    x-hyperfleet-system x-hyperfleet-identity x-extra; do
    grep -qx -- "$header" <<<"$override_headers" || {
        echo "ERROR: $header is not stripped when headers.stripOverride is set" >&2
        exit 1
    }
done
[[ "$(grep -cx -- x-hyperfleet-system <<<"$override_headers")" -eq 1 ]] || {
    echo "ERROR: a header listed in both the fixed list and headers.stripOverride is stripped twice" >&2
    exit 1
}
# The Gateway is named after the release, so neither the old strip list nor a
# gateway name is a value any more.
for removed_key in 'headers.strip={x-only}' 'gateway.name=custom'; do
    if render_gateway NONE --set "$removed_key" >/dev/null 2>&1; then
        echo "ERROR: the removed value ${removed_key%%=*} was accepted" >&2
        exit 1
    fi
done
assert_contains "$(rendered_document "$first_out" Gateway)" '^  name: gw-hyperfleet-gateway$' \
    'the Gateway is not named after the release'

echo "OK: gateway internal TLS, Authorino, and AUTH_MODE templates valid"
