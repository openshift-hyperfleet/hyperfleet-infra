#!/usr/bin/env bash
# shellcheck disable=SC2016
# The single-quoted curl pod scripts and jq filters expand their own variables.
# Exercise the gateway identity boundary, tenant isolation, machine callers,
# reconciliation, tenant-model switching, and the API ingress NetworkPolicy.

set -euo pipefail

PHASE="${1:-}"
NAMESPACE="${NAMESPACE:-}"
HELMFILE_ENV="${HELMFILE_ENV:-}"
OIDC_ISSUER_MODE="${OIDC_ISSUER_MODE:-}"
TENANT_ISOLATION_ENABLED="${TENANT_ISOLATION_ENABLED:-false}"
TENANT_MODEL="${TENANT_MODEL:-onprem}"
GATEWAY_SERVICE="${GATEWAY_SERVICE:-hyperfleet-gateway}"
# Name of the Gateway, which is also the Service name (both are the release name);
# Envoy Gateway labels its proxy pods with it.
GATEWAY_NAME="${GATEWAY_NAME:-$GATEWAY_SERVICE}"
API_SERVICE="${API_SERVICE:-hyperfleet-api}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777}"
GATEWAY_E2E_TIMEOUT="${GATEWAY_E2E_TIMEOUT:-300}"
GATEWAY_E2E_POLL_INTERVAL="${GATEWAY_E2E_POLL_INTERVAL:-5}"

api_path="/api/hyperfleet/v1"
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
run_id="$(date +%s)-${RANDOM}"
pod_labels="app.kubernetes.io/component=gateway-e2e,hyperfleet.io/gateway-e2e-run=${run_id}"
current_cluster_id=""
# Mock issuer tokens expire 600s after minting (helm/mock-oidc tokenExpiry).
# The Cluster owner's token is re-minted once it is half that old, so the
# reconciliation and deletion waits never send an expired token.
owner_token_max_age=300
owner_subject=""
owner_tenant=""
owner_subtenant=""
owner_token=""
owner_token_minted=0
restore_onprem=false
mint_log=""
# The background wristband key rotation and its output file.
rotation_pid=""
rotation_output=""
# The check running now, with a fix to print if it fails.
current_check=""
current_hint=""
passed=0

usage() {
    echo "usage: $0 {human|current-model|full|rotation|shard}" >&2
}

error() {
    echo "ERROR: $*" >&2
}

fail() {
    error "$@"
    exit 1
}

# Name the check that runs next. If the suite stops before pass, on_exit
# prints this check and the optional hint.
check() {
    current_check="$1"
    current_hint="${2:-}"
}

pass() {
    passed=$((passed + 1))
    printf 'PASS  %s  %s\n' "$TENANT_MODEL" "$current_check"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

response_status() {
    printf '%s' "$1" | head -n 1
}

response_body() {
    printf '%s' "$1" | tail -n +2
}

# The expected status is a regex such as 201 or '401|403'.
require_status() {
    local actual
    local expected="$2"
    local description="$3"
    actual=$(response_status "$1")
    [[ "$actual" =~ ^($expected)$ ]] || fail "$description returned HTTP $actual, expected $expected"
}

# Succeed when jq -e accepts the body with the remaining jq arguments.
body_matches() {
    local body="$1"
    shift
    printf '%s' "$body" | jq -e "$@" >/dev/null
}

configure_model() {
    case "$TENANT_MODEL" in
        onprem)
            required_key="org"
            optional_key="project"
            required_header="x-tenant-org"
            optional_header="x-tenant-project"
            tenant_a="hf-gateway-e2e-onprem-a-${run_id}"
            tenant_b="hf-gateway-e2e-onprem-b-${run_id}"
            subtenant_a="project-a"
            subtenant_b="project-b"
            ;;
        oracle)
            required_key="tenancy_ocid"
            optional_key="compartment_id"
            required_header="x-tenant-tenancy-ocid"
            optional_header="x-tenant-compartment"
            tenant_a="ocid1.tenancy.oc1..hf${run_id}a"
            tenant_b="ocid1.tenancy.oc1..hf${run_id}b"
            subtenant_a="ocid1.compartment.oc1..hf${run_id}a"
            subtenant_b="ocid1.compartment.oc1..hf${run_id}b"
            ;;
        *) fail "TENANT_MODEL must be onprem or oracle" ;;
    esac
}

validate_inputs() {
    case "$PHASE" in
        human|current-model|full|rotation|shard) ;;
        *) usage; exit 1 ;;
    esac
    if [[ "$PHASE" == "full" && "$HELMFILE_ENV" != "kind" ]]; then
        fail "full requires HELMFILE_ENV=kind because it verifies Cilium NetworkPolicy enforcement"
    fi
    require_command kubectl
    require_command jq
    [[ -n "$NAMESPACE" ]] || fail "NAMESPACE is required"
    [[ "$OIDC_ISSUER_MODE" == "mock" ]] || fail "$PHASE requires OIDC_ISSUER_MODE=mock"
    [[ "$TENANT_ISOLATION_ENABLED" == "true" ]] || fail "$PHASE requires TENANT_ISOLATION_ENABLED=true"
    configure_model
}

# Print a response as a status line followed by its body. Credentials are read
# from standard input inside the pod and never appear in pod specs or argv.
# Arguments after the body are extra "name: value" request headers.
api_request() {
    local method="$1"
    local path="$2"
    local scheme="$3"
    local token="$4"
    local body=""
    if (( $# >= 5 )); then
        body="$5"
        shift 5
    else
        shift 4
    fi

    printf '%s\n' "$token" | kubectl run "hf-gateway-e2e-request-${run_id}-${RANDOM}" \
        --namespace "$NAMESPACE" \
        --labels="$pod_labels" \
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
scheme="$3"
body="$4"
gateway_service="$5"
shift 5
# Replace each remaining header argument with -H and the header.
n=$#
while [ "$n" -gt 0 ]; do
    set -- "$@" -H "$1"
    shift
    n=$((n - 1))
done
set -- "$@" -sS --connect-timeout 5 --max-time 20 -o /tmp/response -w "%{http_code}" -X "$method" "http://${gateway_service}:8000${path}"
if [ "$scheme" != "none" ]; then
    set -- "$@" -H "Authorization: ${scheme} ${token}"
fi
if [ -n "$body" ]; then
    set -- "$@" -H "Content-Type: application/json" --data-raw "$body"
fi
status=$(curl "$@")
printf "%s\\n" "$status"
cat /tmp/response
' -- "$method" "$path" "$scheme" "$body" "$GATEWAY_SERVICE" "$@"
}

# The helper's diagnostics are shown only when minting fails. Callers override
# TOKEN_AUDIENCE or TENANT_MODEL by prefixing the call.
mint_human_token() {
    TOKEN_SUBJECT="$1" TOKEN_TENANT="$2" TOKEN_SUBTENANT="$3" TOKEN_MISSING_REQUIRED="${4:-false}" \
        "$SCRIPT_DIR/mint-human-token.sh" 2>"$mint_log" || { cat "$mint_log" >&2; return 1; }
}

# Mint the Cluster owner's token when it is missing or older than
# owner_token_max_age. Call it in this shell before each owner request.
refresh_owner_token() {
    if [[ -n "$owner_token" ]] && (( SECONDS - owner_token_minted < owner_token_max_age )); then
        return 0
    fi
    owner_token=$(mint_human_token "$owner_subject" "$owner_tenant" "$owner_subtenant") || return 1
    owner_token_minted=$SECONDS
}

set_owner() {
    owner_subject="$1"
    owner_tenant="$2"
    owner_subtenant="$3"
    owner_token=""
    refresh_owner_token
}

# Send a request on a path unique to this check and require that the gateway
# denied it. Envoy logs UAEX (denied by ext_authz) and no upstream host ("-")
# for a request it answered without contacting the API. Requiring that entry,
# rather than the absence of an API log line, fails when the evidence is
# missing.
expect_denied_at_gateway() {
    local name="$1"
    local scheme="$2"
    local token="$3"
    local expected="${4:-401|403}"
    local path="${api_path}/gateway-e2e-${name}-${TENANT_MODEL}-${run_id}"
    local response entry deadline
    response=$(api_request GET "$path" "$scheme" "$token")
    require_status "$response" "$expected" "$name request"
    deadline=$((SECONDS + GATEWAY_E2E_TIMEOUT))
    while (( SECONDS < deadline )); do
        # Envoy writes access log lines asynchronously, and a pod that cannot
        # serve logs yet is read again on the next poll.
        entry=$(kubectl logs --namespace "$NAMESPACE" -l "gateway.envoyproxy.io/owning-gateway-name=${GATEWAY_NAME}" \
            --container envoy --since=10m --tail=-1 2>/dev/null | grep -F -- " ${path} " || true)
        if [[ -n "$entry" ]]; then
            [[ "$entry" == *" UAEX "* && "$entry" == *'"-"' ]] \
                || fail "gateway forwarded $path to the API instead of denying it at ext_authz"
            return
        fi
        sleep "$GATEWAY_E2E_POLL_INTERVAL"
    done
    fail "gateway access log has no entry for denied request $path within ${GATEWAY_E2E_TIMEOUT}s"
}

# The API returns tenancy as a flat map of the tenant headers it received, so
# an exact match also proves that no forged tenant header was stored.
assert_tenancy() {
    local body="$1"
    local tenant="$2"
    local subtenant="$3"
    body_matches "$body" --arg required "$required_key" --arg tenant "$tenant" \
        --arg optional "$optional_key" --arg subtenant "$subtenant" \
        '.tenancy == ({($required): $tenant} + (if $subtenant == "" then {} else {($optional): $subtenant} end))' \
        || fail "API stored tenancy $(printf '%s' "$body" | jq -c '.tenancy?' 2>/dev/null), expected ${required_key}=${tenant} and ${optional_key}=${subtenant:-<absent>}"
}

wait_for_reconciled() {
    local cluster_id="$1"
    local deadline=$((SECONDS + GATEWAY_E2E_TIMEOUT))
    local response
    while (( SECONDS < deadline )); do
        refresh_owner_token || fail "could not mint a token for the reconciliation poll"
        response=$(api_request GET "${api_path}/clusters/${cluster_id}" Bearer "$owner_token") || fail "reconciliation poll failed"
        if [[ "$(response_status "$response")" == "200" ]] && body_matches "$(response_body "$response")" \
            '.status.conditions[]? | select(.type == "Reconciled" and (.status == "True" or .status == true))'; then
            return
        fi
        sleep "$GATEWAY_E2E_POLL_INTERVAL"
    done
    fail "cluster $cluster_id did not reach Reconciled=True within ${GATEWAY_E2E_TIMEOUT}s"
}

cleanup_current_cluster() {
    if [[ -z "$current_cluster_id" ]]; then
        return 0
    fi
    local response status deadline
    refresh_owner_token || return 1
    response=$(api_request DELETE "${api_path}/clusters/${current_cluster_id}" Bearer "$owner_token") || return 1
    status=$(response_status "$response")
    case "$status" in
        200|202|404) ;;
        *) return 1 ;;
    esac
    deadline=$((SECONDS + GATEWAY_E2E_TIMEOUT))
    while (( SECONDS < deadline )); do
        refresh_owner_token || return 1
        response=$(api_request GET "${api_path}/clusters/${current_cluster_id}" Bearer "$owner_token") || return 1
        if [[ "$(response_status "$response")" == "404" ]]; then
            current_cluster_id=""
            return 0
        fi
        sleep "$GATEWAY_E2E_POLL_INTERVAL"
    done
    error "cluster cleanup did not return HTTP 404 within ${GATEWAY_E2E_TIMEOUT}s"
    return 1
}

cleanup_resources() {
    local rc=0
    cleanup_current_cluster || { error "failed to clean the suite-owned Cluster"; rc=1; }
    kubectl delete pod --namespace "$NAMESPACE" -l "$pod_labels" \
        --ignore-not-found --wait=false >/dev/null 2>&1 || rc=1
    kubectl delete authconfig --namespace "$NAMESPACE" -l hyperfleet.io/gateway-e2e-run="${run_id}" \
        --ignore-not-found --wait=false >/dev/null 2>&1 || rc=1
    rm -f "$mint_log"
    [[ -z "$rotation_output" ]] || rm -f "$rotation_output"
    return "$rc"
}

# Helmfile waits for the gateway and API rollouts. It prints full release
# diffs, so show them only when the switch fails.
switch_model() {
    local output
    output=$(make -C "$REPO_ROOT" --no-print-directory switch-tenant-model TENANT_MODEL="$1" 2>&1) || {
        printf '%s\n' "$output" >&2
        return 1
    }
    TENANT_MODEL="$1"
    configure_model
}

# The AuthConfig can still apply the previous policy right after a switch, so
# poll until the gateway denies an on-prem token and accepts an Oracle one. A
# mint or request can fail while old gateway pods drain, so a failure counts
# as an unsuccessful attempt.
wait_for_oracle_policy() {
    local onprem_subject="$1"
    local onprem_tenant="$2"
    local deadline=$((SECONDS + GATEWAY_E2E_TIMEOUT))
    local onprem_token oracle_token onprem_response oracle_response onprem_status oracle_status
    while (( SECONDS < deadline )); do
        onprem_status="error"
        oracle_status="error"
        if onprem_token=$(TENANT_MODEL=onprem mint_human_token "$onprem_subject" "$onprem_tenant" "") \
            && oracle_token=$(mint_human_token "hf-gateway-e2e-policy-${run_id}@example.com" "$tenant_a" "") \
            && onprem_response=$(api_request GET "${api_path}/clusters" Bearer "$onprem_token") \
            && oracle_response=$(api_request GET "${api_path}/clusters" Bearer "$oracle_token"); then
            onprem_status=$(response_status "$onprem_response")
            oracle_status=$(response_status "$oracle_response")
            if [[ "$onprem_status" == "403" && "$oracle_status" == "200" ]]; then
                return
            fi
        fi
        sleep "$GATEWAY_E2E_POLL_INTERVAL"
    done
    fail "gateway did not enforce the Oracle model within ${GATEWAY_E2E_TIMEOUT}s (on-prem token HTTP ${onprem_status}, Oracle token HTTP ${oracle_status})"
}

# Print the failed check while TENANT_MODEL still names the failing model,
# then clean up, restore on-prem, and print the result.
on_exit() {
    local rc=$?
    trap - EXIT
    if (( rc != 0 )); then
        printf 'FAIL  %s  %s\n' "$TENANT_MODEL" "$current_check"
        [[ -z "$current_hint" ]] || printf '      Fix: %s\n' "$current_hint"
    fi
    # Stopping the rotation midway could leave the gateway release stuck in
    # pending-upgrade, so let it finish instead of outliving the suite.
    if [[ -n "$rotation_pid" ]]; then
        echo "Waiting for the background wristband key rotation to finish..." >&2
        wait "$rotation_pid" || {
            cat "$rotation_output" >&2
            error "wristband key rotation failed: rerun make rotate-wristband-key"
            rc=1
        }
    fi
    cleanup_resources || {
        error "cleanup failed: delete leftover hf-gateway-e2e-* pods and Clusters by hand"
        rc=1
    }
    if [[ "$restore_onprem" == "true" ]]; then
        echo "Restoring tenant model to onprem..." >&2
        switch_model onprem || {
            error "tenant model NOT restored. Run: HELMFILE_ENV=$HELMFILE_ENV OIDC_ISSUER_MODE=mock TENANT_ISOLATION_ENABLED=true make switch-tenant-model TENANT_MODEL=onprem"
            rc=1
        }
    fi
    if (( rc == 0 )); then
        printf '\nResult: PASSED (%d checks)\n' "$passed"
    else
        printf '\nResult: FAILED (%d checks passed)\n' "$passed"
    fi
    exit "$rc"
}

run_human_phase() {
    local subject tenant subtenant response body name token
    if [[ "$PHASE" == "human" ]]; then
        subject="${TOKEN_SUBJECT:-human@example.com}"
        tenant="${TOKEN_TENANT:-}"
        subtenant="${TOKEN_SUBTENANT:-}"
        [[ -n "$tenant" ]] || fail "TOKEN_TENANT is required for the human phase"
    else
        subject="hf-gateway-e2e-human-${run_id}@example.com"
        tenant="$tenant_a"
        subtenant="$subtenant_a"
    fi
    check "valid human token creates a Cluster stamped with its tenant"
    name="hf-gateway-e2e-human-${TENANT_MODEL}-${run_id}"
    set_owner "$subject" "$tenant" "$subtenant"
    response=$(api_request POST "${api_path}/clusters" Bearer "$owner_token" \
        "{\"kind\":\"Cluster\",\"name\":\"${name}\",\"spec\":{\"region\":\"us-east-1\"}}")
    require_status "$response" 201 "valid human token cluster creation"
    body=$(response_body "$response")
    current_cluster_id=$(printf '%s' "$body" | jq -er '.id | select(type == "string" and length > 0)') \
        || fail "valid human token response did not contain a cluster id"
    assert_tenancy "$body" "$tenant" "$subtenant"
    cleanup_current_cluster || fail "could not clean human token smoke resource"
    pass

    # The gateway JWT authentication enforces the audience, so a mismatch fails
    # authentication (401) rather than authorization (403).
    check "token for another audience fails authentication (401)"
    token=$(TOKEN_AUDIENCE=some-other-app mint_human_token "$subject" "$tenant" "$subtenant")
    response=$(api_request GET "${api_path}/clusters" Bearer "$token")
    require_status "$response" 401 "wrong-audience token"
    pass

    check "token without the required ${required_key} claim is denied (403)"
    token=$(mint_human_token "$subject" "$tenant" "$subtenant" true)
    response=$(api_request GET "${api_path}/clusters" Bearer "$token")
    require_status "$response" 403 "missing required claim token"
    pass
}

run_current_model() {
    local subject_a="hf-gateway-e2e-a-${run_id}@example.com"
    local response body name token method
    run_human_phase

    check "missing, invalid, and unknown-scheme credentials are denied at the gateway, never reaching the API"
    expect_denied_at_gateway missing none ""
    expect_denied_at_gateway invalid Bearer "not-a-jwt-${run_id}"
    # Only Bearer (humans) and ServiceAccount (machines) select an
    # authentication method, so any other scheme must be denied.
    expect_denied_at_gateway unknown-scheme Basic "aGY6Z2F0ZXdheS1lMmU="
    pass

    # Authorino overwrites the forged required tenant, system, and identity
    # headers. Tenant A's token has no optional claim, so Authorino sets no
    # optional tenant header and only Envoy's stripping keeps the forged one
    # out of the stored tenancy.
    check "forged identity and tenant headers are replaced, and a forged ${optional_header} is stripped"
    set_owner "$subject_a" "$tenant_a" ""
    name="hf-gateway-e2e-${TENANT_MODEL}-${run_id}"
    response=$(api_request POST "${api_path}/clusters" Bearer "$owner_token" \
        "{\"kind\":\"Cluster\",\"name\":\"${name}\",\"spec\":{\"region\":\"us-east-1\"}}" \
        "${required_header}: forged-tenant" "${optional_header}: forged-subtenant" \
        'x-hyperfleet-system: true' "x-hyperfleet-identity: forged-${run_id}@example.com")
    require_status "$response" 201 "forged-header cluster creation"
    body=$(response_body "$response")
    current_cluster_id=$(printf '%s' "$body" | jq -er '.id | select(type == "string" and length > 0)') \
        || fail "forged-header cluster response did not contain a cluster id"
    assert_tenancy "$body" "$tenant_a" ""
    # The wristband gives the API a caller identity, its subject.
    body_matches "$body" --arg subject "$subject_a" '.created_by == $subject' \
        || fail "API did not record the gateway-derived identity $subject_a as created_by"
    pass

    # The namespace's default ServiceAccount is never on the gateway allow-list.
    check "unlisted ServiceAccount and a ServiceAccount token sent as Bearer are denied"
    token=$(kubectl create token default --namespace "$NAMESPACE" --audience=hyperfleet-api)
    response=$(api_request GET "${api_path}/clusters" ServiceAccount "$token")
    require_status "$response" 403 "unlisted ServiceAccount"
    response=$(api_request GET "${api_path}/clusters" Bearer "$token")
    require_status "$response" '401|403' "ServiceAccount token sent as Bearer"
    pass

    check "Cluster reaches Reconciled=True through Sentinel and adapters" \
        "check the Sentinel and adapter logs; they authenticate to the gateway with their ServiceAccounts"
    wait_for_reconciled "$current_cluster_id"
    pass

    # Tenant B's token is minted here, so it is never older than these requests.
    check "tenant B cannot list, read, patch, or delete tenant A's Cluster after reconciliation"
    token=$(mint_human_token "hf-gateway-e2e-b-${run_id}@example.com" "$tenant_b" "$subtenant_b")
    response=$(api_request GET "${api_path}/clusters" Bearer "$token")
    require_status "$response" 200 "tenant B cluster list"
    body_matches "$(response_body "$response")" --arg id "$current_cluster_id" 'all(.items[]; .id != $id)' \
        || fail "tenant B list contains tenant A cluster $current_cluster_id"
    for method in GET DELETE; do
        response=$(api_request "$method" "${api_path}/clusters/${current_cluster_id}" Bearer "$token")
        require_status "$response" 404 "tenant B $method on tenant A cluster"
    done
    response=$(api_request PATCH "${api_path}/clusters/${current_cluster_id}" Bearer "$token" \
        '{"spec":{"region":"us-west-2"}}')
    require_status "$response" 404 "tenant B PATCH on tenant A cluster"
    pass

    check "Cluster is hard-deleted"
    cleanup_current_cluster || fail "could not hard-delete lifecycle Cluster"
    pass
}

# The probe pod reaches the gateway, then sends the same request directly to
# the API, which the NetworkPolicy must drop (curl exit 28, no HTTP status).
run_network_policy_probe() {
    local output result_pattern='gateway=([0-9]+) api_exit=([0-9]+) api=([0-9]+)'
    check "direct in-cluster request to the API is dropped while the gateway stays reachable" \
        "use the kind cluster from make local-up-kind, which installs Cilium and the NetworkPolicies"
    output=$(kubectl run "hf-gateway-e2e-netpol-${run_id}" --namespace "$NAMESPACE" \
        --labels="$pod_labels" \
        --image="$CURL_IMAGE" --restart=Never --rm --quiet --attach --command -- sh -c '
gateway=$(curl -s --connect-timeout 5 --max-time 10 -o /dev/null -w "%{http_code}" "http://$1:8000/api/hyperfleet/v1/clusters")
api=$(curl -k -s --connect-timeout 5 --max-time 10 -o /dev/null -w "%{http_code}" "https://$2:8000/api/hyperfleet/v1/clusters")
api_exit=$?
printf "gateway=%s api_exit=%s api=%s\\n" "$gateway" "$api_exit" "$api"
' -- "$GATEWAY_SERVICE" "$API_SERVICE") || fail "NetworkPolicy probe pod failed"
    [[ "$output" =~ $result_pattern ]] || fail "NetworkPolicy probe printed no result: $output"
    [[ "${BASH_REMATCH[1]}" != "000" ]] || fail "gateway is unreachable from the probe pod"
    [[ "${BASH_REMATCH[2]}" == "28" && "${BASH_REMATCH[3]}" == "000" ]] \
        || fail "direct API request was not dropped by NetworkPolicy (curl exit ${BASH_REMATCH[2]}, HTTP ${BASH_REMATCH[3]})"
    pass
}

# Shard isolation: the gateway's Authorino selects exactly the AuthConfigs
# labeled hyperfleet.io/gateway=general. A decoy labeled for another shard (the
# Desire Store's) claims the gateway's hosts with a policy that authorizes
# everyone. It must not take effect: a request the decoy would authorize (no
# credential at all) must still be denied, and it must stay status-less, because
# Authorino sets a status on every AuthConfig it watches. Authorino lets the
# incumbent policy keep a duplicated host, so a wrongly watched decoy can be
# behaviorally inert — the status assertion is what catches that case; the
# request assertion is the contract, and catches a decoy that ever wins the host.
run_shard_isolation() {
    local hosts decoy poll conditions
    check "the gateway's Authorino loads no AuthConfig of another shard" \
        "hyperfleet.io/gateway=general is the shard selector; a decoy AuthConfig must stay status-less and authorize nothing"
    hosts=$(kubectl get authconfig hyperfleet-tenant-policy --namespace "$NAMESPACE" \
        -o json | jq -c '.spec.hosts') \
        || fail "could not read the hosts of the live AuthConfig"
    decoy="hf-gateway-e2e-shard-${run_id}"
    kubectl apply --namespace "$NAMESPACE" -f - >/dev/null <<DECOY
apiVersion: authorino.kuadrant.io/v1beta3
kind: AuthConfig
metadata:
  name: ${decoy}
  labels:
    hyperfleet.io/gateway-e2e-run: "${run_id}"
    hyperfleet.io/desire-store: ""
spec:
  hosts: ${hosts}
  authentication:
    "decoy":
      anonymous: {}
DECOY
    for (( poll = 0; poll < 3; poll++ )); do
        sleep "$GATEWAY_E2E_POLL_INTERVAL"
        # Read the whole object and extract with jq: a status-less AuthConfig is
        # an absent .status, not a failed read, and a failed read must fail the
        # check instead of passing as empty.
        conditions=$(kubectl get authconfig "$decoy" --namespace "$NAMESPACE" -o json \
            | jq -r '(.status.conditions // []) | map(.type) | join(" ")') \
            || fail "could not read the decoy AuthConfig $decoy"
        [[ -z "$conditions" ]] || fail "the general Authorino watched $decoy (status: $conditions)"
    done
    [[ "$(kubectl get authconfig hyperfleet-tenant-policy --namespace "$NAMESPACE" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" == "True" ]] \
        || fail "the real AuthConfig is not Ready; the decoy proves nothing without a live watcher"
    # The decoy authorizes everyone, so a request with no credential at all
    # would pass under it; the real policy must deny it.
    expect_denied_at_gateway decoy-shard none ""
    kubectl delete authconfig --namespace "$NAMESPACE" "$decoy" --wait=false >/dev/null
    pass
}

run_full() {
    [[ "$TENANT_MODEL" == "onprem" ]] || fail "full must start with TENANT_MODEL=onprem"
    local onprem_subject="hf-gateway-e2e-old-${run_id}@example.com"
    local onprem_tenant="$tenant_a"
    local token
    run_network_policy_probe
    run_current_model
    run_shard_isolation

    # The mock issuer serves both models, so on-prem tokens are minted after
    # the switch with the claims the on-prem pass just accepted. No token has
    # to outlive the switch.
    check "tenant model switches to Oracle through configuration only" \
        "nothing else may redeploy the gateway or API while the suite runs"
    restore_onprem=true
    switch_model oracle
    wait_for_oracle_policy "$onprem_subject" "$onprem_tenant"
    pass

    check "on-prem token is rejected at the gateway after the switch" \
        "nothing else may redeploy the gateway or API while the suite runs"
    token=$(TENANT_MODEL=onprem mint_human_token "$onprem_subject" "$onprem_tenant" "")
    expect_denied_at_gateway old-token Bearer "$token" 403
    pass

    run_current_model
}

signing_keys() {
    kubectl get authconfig hyperfleet-tenant-policy --namespace "$NAMESPACE" \
        -o jsonpath='{.spec.response.success.dynamicMetadata.wristband.wristband.signingKeyRefs[*].name}'
}

jwks_key_ids() {
    kubectl get --raw "/api/v1/namespaces/${NAMESPACE}/services/https:authorino-authorino-oidc:8083/proxy/${NAMESPACE}/hyperfleet-tenant-policy/wristband/.well-known/openid-connect/certs" \
        | jq -r '[.keys[].kid] | join(" ")'
}

# Require that the rotation left exactly one key, a new one, that Authorino
# publishes only it, and that every key it replaced is deleted.
assert_rotated() {
    local before="$1" after="$2" key
    [[ -n "$after" && "$after" != *" "* ]] || fail "AuthConfig signs with '$after', expected one key"
    [[ " $before " != *" $after "* ]] || fail "AuthConfig still signs with $after, a key from before the rotation"
    [[ "$(jwks_key_ids)" == "$after" ]] || fail "Authorino publishes '$(jwks_key_ids)', expected only $after"
    for key in $before; do
        ! kubectl get secret "$key" --namespace "$NAMESPACE" >/dev/null 2>&1 \
            || fail "replaced signing key Secret $key was not deleted"
    done
    [[ "$(kubectl get secret --namespace "$NAMESPACE" -l hyperfleet.io/wristband-signing-key -o name)" == "secret/$after" ]] \
        || fail "signing key Secrets other than $after remain"
}

# A rotation without REVOKE must not fail a single request, so the requests
# run one after another for as long as the rotation runs, including its wait
# for old wristbands to expire.
run_rotation() {
    local before after output response status requests=0 failures=0 rotation_rc=0
    set_owner "hf-gateway-e2e-rotation-${run_id}@example.com" "$tenant_a" ""

    check "wristband signing key rotates without a failed request"
    before=$(signing_keys)
    rotation_output=$(mktemp)
    make -C "$REPO_ROOT" --no-print-directory rotate-wristband-key REVOKE=false >"$rotation_output" 2>&1 &
    rotation_pid=$!
    while kill -0 "$rotation_pid" 2>/dev/null; do
        refresh_owner_token || fail "could not mint a token during the rotation"
        status="error"
        response=$(api_request GET "${api_path}/clusters" Bearer "$owner_token") \
            && status=$(response_status "$response")
        requests=$((requests + 1))
        [[ "$status" == "200" ]] || failures=$((failures + 1))
    done
    wait "$rotation_pid" || rotation_rc=$?
    rotation_pid=""
    (( rotation_rc == 0 )) || { cat "$rotation_output" >&2; fail "make rotate-wristband-key failed"; }
    (( failures == 0 )) || fail "$failures of $requests requests failed during the rotation"
    after=$(signing_keys)
    assert_rotated "$before" "$after"
    pass

    # sync always upgrades, so the chart re-renders the keys from the live
    # AuthConfig without the rotation's one-off value.
    check "a gateway redeploy keeps the rotated key"
    output=$(helmfile -f "$REPO_ROOT/helmfile/helmfile.yaml.gotmpl" -e "$HELMFILE_ENV" \
        -l component=gateway sync 2>&1) || { printf '%s\n' "$output" >&2; fail "gateway sync failed"; }
    [[ "$(signing_keys)" == "$after" ]] || fail "gateway redeploy changed the signing keys to '$(signing_keys)', expected $after"
    pass

    check "revoked unlabeled wristband signing key is replaced at once and requests succeed"
    before="$after"
    # A key from a deployment before keys were labeled has no label.
    kubectl label secret "$before" --namespace "$NAMESPACE" hyperfleet.io/wristband-signing-key- >/dev/null
    output=$(make -C "$REPO_ROOT" --no-print-directory rotate-wristband-key REVOKE=true 2>&1) \
        || { printf '%s\n' "$output" >&2; fail "make rotate-wristband-key REVOKE=true failed"; }
    assert_rotated "$before" "$(signing_keys)"
    refresh_owner_token || fail "could not mint a token after the revocation"
    response=$(api_request GET "${api_path}/clusters" Bearer "$owner_token")
    require_status "$response" 200 "request after the revocation"
    pass
}

validate_inputs
# mint-human-token.sh reads these from the environment.
export NAMESPACE OIDC_ISSUER_MODE TENANT_MODEL
mint_log=$(mktemp)
trap on_exit EXIT
check "HyperFleet stack is deployed and ready" \
    "bring it up with: HELMFILE_ENV=kind OIDC_ISSUER_MODE=mock TENANT_ISOLATION_ENABLED=true make local-up-kind"
kubectl wait --for=condition=Programmed "gateway/${GATEWAY_NAME}" --namespace "$NAMESPACE" \
    --timeout="${GATEWAY_E2E_TIMEOUT}s" >/dev/null
kubectl wait --for=condition=Available deployment --namespace "$NAMESPACE" \
    -l "gateway.envoyproxy.io/owning-gateway-name=${GATEWAY_NAME}" \
    --timeout="${GATEWAY_E2E_TIMEOUT}s" >/dev/null
kubectl wait --for=condition=Available deployment --namespace "$NAMESPACE" \
    -l 'app.kubernetes.io/name in (mock-oidc,hyperfleet-api,hyperfleet-sentinel,hyperfleet-adapter)' \
    --timeout="${GATEWAY_E2E_TIMEOUT}s" >/dev/null
kubectl wait --for=condition=Ready authconfig/hyperfleet-tenant-policy \
    --namespace "$NAMESPACE" --timeout="${GATEWAY_E2E_TIMEOUT}s" >/dev/null
pass
case "$PHASE" in
    human) run_human_phase ;;
    current-model) run_current_model ;;
    full) run_full ;;
    rotation) run_rotation ;;
    shard) run_shard_isolation ;;
esac
