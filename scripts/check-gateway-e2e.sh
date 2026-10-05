#!/usr/bin/env bash
# shellcheck disable=SC2016
# The nested single-quoted scripts run in short-lived in-cluster curl pods.
# Exercise the gateway identity boundary, tenant isolation, machine callers,
# reconciliation, tenant-model switching, and the API ingress NetworkPolicy.

set -euo pipefail

PHASE="${1:-}"
NAMESPACE="${NAMESPACE:-}"
HELMFILE_ENV="${HELMFILE_ENV:-}"
OIDC_ISSUER_MODE="${OIDC_ISSUER_MODE:-}"
EXT_AUTHZ_ENABLED="${EXT_AUTHZ_ENABLED:-false}"
TENANT_ISOLATION_ENABLED="${TENANT_ISOLATION_ENABLED:-false}"
TENANT_MODEL="${TENANT_MODEL:-onprem}"
GATEWAY_SERVICE="${GATEWAY_SERVICE:-hyperfleet-gateway}"
API_SERVICE="${API_SERVICE:-hyperfleet-api}"
CILIUM_NAMESPACE="${CILIUM_NAMESPACE:-kube-system}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777}"
GATEWAY_E2E_TIMEOUT="${GATEWAY_E2E_TIMEOUT:-300}"
GATEWAY_E2E_POLL_INTERVAL="${GATEWAY_E2E_POLL_INTERVAL:-5}"

api_path="/api/hyperfleet/v1"
script_dir=$(dirname -- "$0")
SCRIPT_DIR=$(cd -- "$script_dir" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
run_id="$(date +%s)-${RANDOM}"
current_cluster_id=""
current_cluster_token=""
temporary_service_account=""
restore_onprem=false

usage() {
    echo "usage: $0 {human|current-model|full}" >&2
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require_status() {
    local actual="$1"
    local expected="$2"
    local description="$3"
    [[ "$actual" == "$expected" ]] || fail "$description returned HTTP $actual, expected $expected"
}

require_denial() {
    local actual="$1"
    local description="$2"
    case "$actual" in
        401|403) ;;
        *) fail "$description returned HTTP $actual, expected 401 or 403" ;;
    esac
}

validate_integer() {
    local name="$1"
    local value="$2"
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || fail "$name must be a positive integer"
}

validate_header() {
    local header="$1"
    [[ "$header" =~ ^[A-Za-z0-9-]+=[A-Za-z0-9._:@+-]*$ ]] || fail "unsupported forged header value"
}

configure_model() {
    case "$TENANT_MODEL" in
        onprem)
            required_key="org"
            optional_key="project"
            tenant_a="hf-gateway-e2e-onprem-a-${run_id}"
            tenant_b="hf-gateway-e2e-onprem-b-${run_id}"
            subtenant_a="project-a"
            subtenant_b="project-b"
            ;;
        oracle)
            required_key="tenancy_ocid"
            optional_key="compartment_id"
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
        human|current-model|full) ;;
        *) usage; exit 1 ;;
    esac
    require_command kubectl
    require_command jq
    [[ -n "$NAMESPACE" ]] || fail "NAMESPACE is required"
    [[ "$OIDC_ISSUER_MODE" == "mock" ]] || fail "$PHASE requires OIDC_ISSUER_MODE=mock"
    [[ "$EXT_AUTHZ_ENABLED" == "true" ]] || fail "$PHASE requires EXT_AUTHZ_ENABLED=true"
    [[ "$TENANT_ISOLATION_ENABLED" == "true" ]] || fail "$PHASE requires TENANT_ISOLATION_ENABLED=true"
    validate_integer GATEWAY_E2E_TIMEOUT "$GATEWAY_E2E_TIMEOUT"
    validate_integer GATEWAY_E2E_POLL_INTERVAL "$GATEWAY_E2E_POLL_INTERVAL"
    configure_model
    if [[ "$PHASE" == "full" && "$HELMFILE_ENV" != "kind" ]]; then
        fail "full requires HELMFILE_ENV=kind because it verifies Cilium NetworkPolicy enforcement"
    fi
}

wait_for_deployment() {
    local deployment="$1"
    kubectl rollout status "deployment/${deployment}" --namespace "$NAMESPACE" \
        --timeout="${GATEWAY_E2E_TIMEOUT}s" >/dev/null
}

wait_for_components() {
    kubectl wait --for=condition=Available deployment/hyperfleet-mock-oidc \
        --namespace "$NAMESPACE" --timeout="${GATEWAY_E2E_TIMEOUT}s" >/dev/null
    kubectl wait --for=condition=Ready authconfig/hyperfleet-tenant-policy \
        --namespace "$NAMESPACE" --timeout="${GATEWAY_E2E_TIMEOUT}s" >/dev/null
    wait_for_deployment "$GATEWAY_SERVICE"
    wait_for_deployment "$API_SERVICE"

    local sentinel_deployments adapter_deployments component_deployments
    sentinel_deployments=$(kubectl get deployments --namespace "$NAMESPACE" \
        -l app.kubernetes.io/name=hyperfleet-sentinel -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
    adapter_deployments=$(kubectl get deployments --namespace "$NAMESPACE" \
        -l app.kubernetes.io/name=hyperfleet-adapter -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
    [[ -n "$sentinel_deployments" ]] || fail "no Sentinel deployments found in namespace $NAMESPACE"
    [[ -n "$adapter_deployments" ]] || fail "no adapter deployments found in namespace $NAMESPACE"
    component_deployments=$(printf '%s\n%s\n' "$sentinel_deployments" "$adapter_deployments" | sort -u)
    while IFS= read -r deployment; do
        [[ -n "$deployment" ]] && wait_for_deployment "$deployment"
    done <<<"$component_deployments"
}

# Print a response as a status line followed by its body. Credentials are read
# from standard input inside the pod and never appear in pod specs or argv.
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
    local pod_name="hf-gateway-e2e-request-${run_id}-${RANDOM}"
    local header
    for header in "$@"; do
        validate_header "$header"
    done

    printf '%s\n' "$token" | kubectl run "$pod_name" \
        --namespace "$NAMESPACE" \
        --labels="app.kubernetes.io/component=gateway-e2e,hyperfleet.io/gateway-e2e-run=${run_id}" \
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
response_file=/tmp/response
headers="$*"
set -- -sS --connect-timeout 5 --max-time 20 -o "$response_file" -w "%{http_code}" -X "$method" "http://${gateway_service}:8000${path}"
if [ "$scheme" != "none" ]; then
    set -- "$@" -H "Authorization: ${scheme} ${token}"
fi
if [ -n "$body" ]; then
    set -- "$@" -H "Content-Type: application/json" --data-raw "$body"
fi
# Header values are validated by the outer script and contain no whitespace, so
# this split preserves each header as one curl argument without eval.
for header in $headers; do
    set -- "$@" -H "$header"
done
status=$(curl "$@")
printf "%s\\n" "$status"
cat "$response_file"
' -- "$method" "$path" "$scheme" "$body" "$GATEWAY_SERVICE" "$@"
}

# The curl command above deliberately receives only validated fixed header
# values. Keep the implementation below separate from its response parsing.
response_status() {
    printf '%s' "$1" | head -n 1
}

response_body() {
    printf '%s' "$1" | tail -n +2
}

mint_human_token() {
    local subject="$1"
    local tenant="$2"
    local subtenant="$3"
    local missing_required="${4:-false}"
    TOKEN_MISSING_REQUIRED="$missing_required" \
        TOKEN_AUDIENCE="${TOKEN_AUDIENCE:-hyperfleet-api}" \
        TOKEN_SUBJECT="$subject" \
        TOKEN_TENANT="$tenant" \
        TOKEN_SUBTENANT="$subtenant" \
        TENANT_MODEL="$TENANT_MODEL" \
        OIDC_ISSUER_MODE=mock NAMESPACE="$NAMESPACE" \
        "$SCRIPT_DIR/mint-human-token.sh"
}

assert_api_nonarrival() {
    local path="$1"
    local pods pod logs
    pods=$(kubectl get pods --namespace "$NAMESPACE" \
        -l app.kubernetes.io/name=hyperfleet-api -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
    [[ -n "$pods" ]] || fail "could not find API pods for denied request non-arrival"
    while IFS= read -r pod; do
        [[ -n "$pod" ]] || continue
        logs=$(kubectl logs "$pod" --namespace "$NAMESPACE" --since=2m) \
            || fail "could not inspect API logs for denied request non-arrival"
        if printf '%s\n' "$logs" | grep -Fq -- "$path"; then
            fail "denied request path reached the API: $path"
        fi
    done <<<"$pods"
}

assert_tenant_stamped() {
    local body="$1"
    local tenant="$2"
    if ! printf '%s' "$body" | jq -e --arg key "$required_key" --arg value "$tenant" \
        '[.. | objects | select(has($key)) | .[$key]] | any(. == $value)' >/dev/null; then
        fail "API response did not stamp ${required_key} from the gateway token"
    fi
}

assert_gateway_identity_stamped() {
    local body="$1"
    local subject="$2"
    if ! printf '%s' "$body" | jq -e --arg subject "$subject" \
        '[.. | objects | select(.created_by? == $subject or .updated_by? == $subject)] | length > 0' >/dev/null; then
        fail "API response did not record the gateway-derived audit identity"
    fi
}

assert_optional_tenant_stamped() {
    local body="$1"
    local subtenant="$2"
    if [[ -n "$subtenant" ]]; then
        if ! printf '%s' "$body" | jq -e --arg key "$optional_key" --arg value "$subtenant" \
            '[.. | objects | select(has($key)) | .[$key]] | any(. == $value)' >/dev/null; then
            fail "API response did not stamp optional ${optional_key} from the gateway token"
        fi
    elif ! printf '%s' "$body" | jq -e --arg key "$optional_key" \
        '[.. | objects | select(has($key))] | length == 0' >/dev/null; then
        fail "API response unexpectedly contained optional ${optional_key}"
    fi
}

assert_cluster_absent_from_list() {
    local body="$1"
    local cluster_id="$2"
    if printf '%s' "$body" | jq -e --arg id "$cluster_id" \
        '[.. | objects | .id? | select(. == $id)] | length == 0' >/dev/null; then
        return
    fi
    fail "tenant B list unexpectedly contains tenant A cluster $cluster_id"
}

wait_for_status() {
    local token="$1"
    local path="$2"
    local expected="$3"
    local description="$4"
    local deadline=$((SECONDS + GATEWAY_E2E_TIMEOUT))
    local response status
    while (( SECONDS < deadline )); do
        response=$(api_request GET "$path" Bearer "$token") || {
            echo "ERROR: $description request failed" >&2
            return 1
        }
        status=$(response_status "$response")
        [[ "$status" == "$expected" ]] && return
        sleep "$GATEWAY_E2E_POLL_INTERVAL"
    done
    echo "ERROR: $description did not return HTTP $expected within ${GATEWAY_E2E_TIMEOUT}s" >&2
    return 1
}

wait_for_reconciled() {
    local token="$1"
    local cluster_id="$2"
    local deadline=$((SECONDS + GATEWAY_E2E_TIMEOUT))
    local response status body
    while (( SECONDS < deadline )); do
        response=$(api_request GET "${api_path}/clusters/${cluster_id}" Bearer "$token") || fail "reconciliation poll failed"
        status=$(response_status "$response")
        body=$(response_body "$response")
        if [[ "$status" == "200" ]] && printf '%s' "$body" | jq -e \
            '.status.conditions[]? | select(.type == "Reconciled" and (.status == "True" or .status == true))' >/dev/null; then
            return
        fi
        sleep "$GATEWAY_E2E_POLL_INTERVAL"
    done
    fail "cluster $cluster_id did not reach Reconciled=True within ${GATEWAY_E2E_TIMEOUT}s"
}

cleanup_current_cluster() {
    if [[ -z "$current_cluster_id" || -z "$current_cluster_token" ]]; then
        return 0
    fi
    local response status
    response=$(api_request DELETE "${api_path}/clusters/${current_cluster_id}" Bearer "$current_cluster_token") || return 1
    status=$(response_status "$response")
    case "$status" in
        200|202|404) ;;
        *) return 1 ;;
    esac
    wait_for_status "$current_cluster_token" "${api_path}/clusters/${current_cluster_id}" 404 "cluster cleanup" || return 1
    current_cluster_id=""
    current_cluster_token=""
}

cleanup_resources() {
    local rc=0
    cleanup_current_cluster || { echo "ERROR: failed to clean the suite-owned Cluster" >&2; rc=1; }
    if [[ -n "$temporary_service_account" ]]; then
        kubectl delete serviceaccount "$temporary_service_account" --namespace "$NAMESPACE" \
            --ignore-not-found >/dev/null 2>&1 || { echo "ERROR: failed to delete temporary ServiceAccount" >&2; rc=1; }
        temporary_service_account=""
    fi
    kubectl delete pod --namespace "$NAMESPACE" \
        -l "app.kubernetes.io/component=gateway-e2e,hyperfleet.io/gateway-e2e-run=${run_id}" \
        --ignore-not-found --wait=false >/dev/null 2>&1 || rc=1
    return "$rc"
}

restore_model() {
    echo "Restoring tenant model to onprem..." >&2
    if ! make -C "$REPO_ROOT" switch-tenant-model TENANT_MODEL=onprem; then
        echo "ERROR: automatic restoration failed; run: HELMFILE_ENV=kind EXT_AUTHZ_ENABLED=true TENANT_ISOLATION_ENABLED=true make switch-tenant-model TENANT_MODEL=onprem" >&2
        return 1
    fi
    TENANT_MODEL=onprem
    configure_model
    wait_for_components
}

on_exit() {
    local original_status="$1"
    local cleanup_status=0
    local restore_status=0
    trap - EXIT
    cleanup_resources || cleanup_status=1
    if [[ "$restore_onprem" == "true" ]]; then
        restore_model || restore_status=1
    fi
    if (( original_status != 0 )); then
        exit "$original_status"
    fi
    if (( cleanup_status != 0 || restore_status != 0 )); then
        exit 1
    fi
}
trap 'on_exit $?' EXIT

run_human_phase() {
    local subject tenant subtenant
    local token response status body cluster_id name wrong_audience_token missing_token lookup_response lookup_body
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
    name="hf-gateway-e2e-human-${run_id}"
    token=$(mint_human_token "$subject" "$tenant" "$subtenant")
    response=$(api_request POST "${api_path}/clusters" Bearer "$token" \
        "{\"kind\":\"Cluster\",\"name\":\"${name}\",\"spec\":{\"region\":\"us-east-1\"}}")
    status=$(response_status "$response")
    body=$(response_body "$response")
    require_status "$status" 201 "valid human token cluster creation"
    cluster_id=$(printf '%s' "$body" | jq -er '.id | select(type == "string" and length > 0)' 2>/dev/null || true)
    if [[ -z "$cluster_id" ]]; then
        lookup_response=$(api_request GET "${api_path}/clusters" Bearer "$token") || fail "could not list the valid human token resource"
        require_status "$(response_status "$lookup_response")" 200 "valid human token cluster list"
        lookup_body=$(response_body "$lookup_response")
        cluster_id=$(printf '%s' "$lookup_body" | jq -er --arg name "$name" \
            '[.. | objects | select(.name? == $name) | .id? | select(type == "string" and length > 0)][0]' 2>/dev/null || true)
        [[ -n "$cluster_id" ]] || fail "valid human token response did not contain a cluster id and the created resource could not be found"
    fi
    assert_tenant_stamped "$body" "$tenant"
    assert_optional_tenant_stamped "$body" "$subtenant"
    current_cluster_id="$cluster_id"
    current_cluster_token="$token"
    cleanup_current_cluster || fail "could not clean human token smoke resource"
    printf 'PASS: valid %s human token propagated gateway-derived tenant\n' "$TENANT_MODEL"

    wrong_audience_token=$(TOKEN_AUDIENCE=some-other-app mint_human_token "$subject" "$tenant" "$subtenant")
    response=$(api_request GET "${api_path}/clusters" Bearer "$wrong_audience_token")
    require_status "$(response_status "$response")" 403 "wrong-audience token"
    printf 'PASS: wrong-audience human token was denied\n'

    missing_token=$(mint_human_token "$subject" "$tenant" "$subtenant" true)
    response=$(api_request GET "${api_path}/clusters" Bearer "$missing_token")
    require_status "$(response_status "$response")" 403 "missing required claim token"
    printf 'PASS: human token missing %s was denied\n' "$required_key"
    if [[ "$PHASE" == "human" ]]; then
        printf 'OK: human token source and gateway tenant propagation check passed (mode=mock model=%s)\n' "$TENANT_MODEL"
    fi
}

assert_isolation() {
    local tenant_b_token="$1"
    local cluster_id="$2"
    local response status body
    response=$(api_request GET "${api_path}/clusters" Bearer "$tenant_b_token")
    require_status "$(response_status "$response")" 200 "tenant B cluster list"
    body=$(response_body "$response")
    assert_cluster_absent_from_list "$body" "$cluster_id"
    for method in GET DELETE; do
        response=$(api_request "$method" "${api_path}/clusters/${cluster_id}" Bearer "$tenant_b_token")
        require_status "$(response_status "$response")" 404 "tenant B $method on tenant A cluster"
    done
    response=$(api_request PATCH "${api_path}/clusters/${cluster_id}" Bearer "$tenant_b_token" \
        '{"spec":{"region":"us-west-2"}}')
    require_status "$(response_status "$response")" 404 "tenant B PATCH on tenant A cluster"
}

run_machine_denials() {
    local token response
    temporary_service_account="hf-gateway-e2e-unlisted-${run_id}"
    kubectl create serviceaccount "$temporary_service_account" --namespace "$NAMESPACE" >/dev/null
    token=$(kubectl create token "$temporary_service_account" --namespace "$NAMESPACE" --audience=hyperfleet-api)
    response=$(api_request GET "${api_path}/clusters" ServiceAccount "$token")
    require_status "$(response_status "$response")" 403 "unlisted ServiceAccount"
    response=$(api_request GET "${api_path}/clusters" Bearer "$token")
    require_denial "$(response_status "$response")" "ServiceAccount token sent as Bearer"
    printf 'PASS: unlisted ServiceAccount and ServiceAccount-as-Bearer were denied\n'
}

verify_tenant_body_immutable() {
    local token="$1"
    local cluster_id="$2"
    local tenant="$3"
    local response status body
    response=$(api_request PATCH "${api_path}/clusters/${cluster_id}" Bearer "$token" \
        "{\"spec\":{\"region\":\"us-east-1\"},\"${required_key}\":\"forged-body-tenant\"}")
    status=$(response_status "$response")
    case "$status" in
        400|422)
            printf 'PASS: API schema rejected a client-supplied %s field\n' "$required_key"
            ;;
        200)
            response=$(api_request GET "${api_path}/clusters/${cluster_id}" Bearer "$token")
            require_status "$(response_status "$response")" 200 "tenant immutability readback"
            body=$(response_body "$response")
            assert_tenant_stamped "$body" "$tenant"
            printf 'PASS: API retained gateway-derived %s after an accepted patch\n' "$required_key"
            ;;
        *) fail "tenant immutability patch returned HTTP $status, expected 200, 400, or 422" ;;
    esac
}

run_denial_nonarrival() {
    local missing_path invalid_path response
    missing_path="${api_path}/gateway-e2e-missing-${run_id}"
    response=$(api_request GET "$missing_path" none "")
    require_denial "$(response_status "$response")" "missing credential"
    assert_api_nonarrival "$missing_path"
    invalid_path="${api_path}/gateway-e2e-invalid-${run_id}"
    response=$(api_request GET "$invalid_path" Bearer "not-a-jwt-${run_id}")
    require_denial "$(response_status "$response")" "invalid credential"
    assert_api_nonarrival "$invalid_path"
    printf 'PASS: missing and invalid credentials were rejected before the API\n'
}

run_current_model() {
    local subject_a="hf-gateway-e2e-a-${run_id}@example.com"
    local subject_b="hf-gateway-e2e-b-${run_id}@example.com"
    local token_a token_b response status body name
    run_human_phase
    run_denial_nonarrival
    token_a=$(mint_human_token "$subject_a" "$tenant_a" "$subtenant_a")
    token_b=$(mint_human_token "$subject_b" "$tenant_b" "$subtenant_b")
    name="hf-gateway-e2e-${TENANT_MODEL}-${run_id}"
    response=$(api_request POST "${api_path}/clusters" Bearer "$token_a" \
        "{\"kind\":\"Cluster\",\"name\":\"${name}\",\"spec\":{\"region\":\"us-east-1\"}}" \
        'x-tenant-org=forged-org' 'x-tenant-project=forged-project' \
        'x-tenant-tenancy-ocid=forged-tenancy' 'x-tenant-compartment=forged-compartment' \
        'x-hyperfleet-system=true' 'x-hyperfleet-identity=forged@example.com')
    status=$(response_status "$response")
    body=$(response_body "$response")
    require_status "$status" 201 "forged-header cluster creation"
    current_cluster_id=$(printf '%s' "$body" | jq -er '.id | select(type == "string" and length > 0)') \
        || fail "forged-header cluster response did not contain a cluster id"
    current_cluster_token="$token_a"
    assert_tenant_stamped "$body" "$tenant_a"
    assert_gateway_identity_stamped "$body" "$subject_a"
    if ! printf '%s' "$body" | jq -e --arg forged "forged-org" --arg forged_oracle "forged-tenancy" \
        '[.. | strings | select(. == $forged or . == $forged_oracle)] | length == 0' >/dev/null; then
        fail "API response retained a forged tenant header value"
    fi
    printf 'PASS: gateway replaced forged identity, system, and tenant headers\n'

    verify_tenant_body_immutable "$token_a" "$current_cluster_id" "$tenant_a"

    assert_isolation "$token_b" "$current_cluster_id"
    printf 'PASS: tenant B could not list, read, patch, or delete tenant A resource before reconciliation\n'
    run_machine_denials
    wait_for_reconciled "$token_a" "$current_cluster_id"
    printf 'PASS: tenant A Cluster reached Reconciled=True through Sentinel and adapters\n'
    assert_isolation "$token_b" "$current_cluster_id"
    printf 'PASS: tenant B isolation held after reconciliation\n'
    cleanup_current_cluster || fail "could not hard-delete lifecycle Cluster"
    printf 'PASS: tenant A Cluster was hard-deleted\n'

    # Keep a valid token only in shell memory for the full phase's post-probe
    # gateway reachability check. It is never printed or passed in argv.
    current_model_gateway_token="$token_a"
}

verify_cilium_policy_posture() {
    kubectl rollout status daemonset/cilium --namespace "$CILIUM_NAMESPACE" \
        --timeout="${GATEWAY_E2E_TIMEOUT}s" >/dev/null
    kubectl get networkpolicy hyperfleet-api-ingress --namespace "$NAMESPACE" >/dev/null
}

run_network_policy_probe() {
    local response status pod_name output curl_exit http_status
    response=$(api_request GET "${api_path}/clusters" Bearer "$current_model_gateway_token")
    require_status "$(response_status "$response")" 200 "gateway reachability before NetworkPolicy probe"
    pod_name="hf-gateway-e2e-netpol-${run_id}"
    output=$(kubectl run "$pod_name" --namespace "$NAMESPACE" \
        --labels="app.kubernetes.io/component=gateway-e2e,hyperfleet.io/gateway-e2e-run=${run_id}" \
        --image="$CURL_IMAGE" --restart=Never --rm --quiet --attach --command -- sh -c '
set +e
status=$(curl -k -sS --connect-timeout 5 --max-time 10 -o /tmp/body -w "%{http_code}" "https://$1:8000/api/hyperfleet/v1/clusters")
rc=$?
printf "curl_exit=%s http_status=%s\\n" "$rc" "$status"
exit 0
' -- "$API_SERVICE") || fail "direct API NetworkPolicy probe pod failed"
    curl_exit=$(printf '%s\n' "$output" | sed -n 's/.*curl_exit=\([0-9][0-9]*\).*/\1/p')
    http_status=$(printf '%s\n' "$output" | sed -n 's/.*http_status=\([0-9][0-9]*\).*/\1/p')
    [[ "$curl_exit" == "28" && "$http_status" == "000" ]] || \
        fail "direct API probe was not dropped by NetworkPolicy (curl_exit=${curl_exit:-unknown} http_status=${http_status:-unknown})"
    response=$(api_request GET "${api_path}/clusters" Bearer "$current_model_gateway_token")
    require_status "$(response_status "$response")" 200 "gateway reachability after NetworkPolicy probe"
    printf 'PASS: direct in-cluster API connection was dropped while gateway remained reachable\n'
}

run_full() {
    [[ "$TENANT_MODEL" == "onprem" ]] || fail "full must start with TENANT_MODEL=onprem"
    verify_cilium_policy_posture
    local old_token response
    old_token=$(mint_human_token "hf-gateway-e2e-old-${run_id}@example.com" "$tenant_a" "$subtenant_a")
    run_current_model
    restore_onprem=true
    make -C "$REPO_ROOT" switch-tenant-model TENANT_MODEL=oracle
    TENANT_MODEL=oracle
    configure_model
    wait_for_components
    response=$(api_request GET "${api_path}/clusters" Bearer "$old_token")
    require_status "$(response_status "$response")" 403 "on-prem token after Oracle switch"
    printf 'PASS: on-prem token was rejected after the Oracle model switch\n'
    run_current_model
    run_network_policy_probe
    printf 'OK: full gateway end-to-end suite passed for on-prem and Oracle; cleanup and model restoration follow\n'
}

validate_inputs
wait_for_components
case "$PHASE" in
    human) run_human_phase ;;
    current-model) run_current_model ;;
    full) run_full ;;
esac
