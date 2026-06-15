#!/usr/bin/env bash
set -uo pipefail

# ── Constants ──

CTX_DOGFOOD="gke_hcm-hyperfleet_us-central1-a_hyperfleet-dev-hackathon-dogfood"
CTX_BUILD="gke_hcm-hyperfleet_us-central1-a_hyperfleet-dev-hackathon-build"
CTX_OPERATE="gke_hcm-hyperfleet_us-central1-a_hyperfleet-dev-hackathon-operate"

NS_HEALTHY="hyperfleet-healthy"
NS_BROKEN_AMERICAS="hyperfleet-broken-americas"
NS_BROKEN_EUROPE="hyperfleet-broken-europe"
NS_HYPERFLEET="hyperfleet"
NS_MONITORING="monitoring"

API_IDENTITY_HEADER="-H X-HyperFleet-Identity:smoke-test@redhat.com"
API_PORT=8000
RECONCILE_TIMEOUT=120
SMOKE_CLUSTER_NAME="smoke-test-$(date +%Y%m%d)"

# ── State ──

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
KNOWN_COUNT=0
FAILURES=()
CLUSTER_FILTER="all"
CLEANUP=true

# ── Argument Parsing ──

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cluster)
        CLUSTER_FILTER="$2"
        shift 2
        ;;
      --no-cleanup)
        CLEANUP=false
        shift
        ;;
      *)
        echo "Usage: $0 [--cluster dogfood|build|operate|all] [--no-cleanup]"
        exit 1
        ;;
    esac
  done
}

# ── Output Helpers ──

section() {
  echo ""
  echo "── $1 ──"
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  PASS  $1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILURES+=("$1")
  echo "  FAIL  $1"
}

warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  echo "  WARN  $1"
}

known_issue() {
  KNOWN_COUNT=$((KNOWN_COUNT + 1))
  echo "  KNOWN ISSUE  $1"
}

# ── Prerequisites ──

check_prereqs() {
  local missing=()
  command -v kubectl &>/dev/null || missing+=("kubectl")
  command -v curl &>/dev/null || missing+=("curl")
  command -v jq &>/dev/null || missing+=("jq")
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: missing required tools: ${missing[*]}"
    exit 1
  fi
}

check_context() {
  local ctx="$1" label="$2"
  if ! kubectl config get-contexts "$ctx" &>/dev/null; then
    fail "[$label] kubectl context not found: $ctx"
    return 1
  fi
  return 0
}

# ── Infrastructure Helpers ──

get_api_url() {
  local ctx="$1" ns="$2"
  local ip
  ip=$(kubectl --context "$ctx" get svc hyperfleet-api -n "$ns" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  if [[ -z "$ip" ]]; then
    return 1
  fi
  echo "http://${ip}:${API_PORT}"
}

check_pods_running() {
  local ctx="$1" ns="$2" label="$3"
  local not_ready
  not_ready=$(kubectl --context "$ctx" get pods -n "$ns" -o json 2>/dev/null \
    | jq -r '[.items[] | select(.status.phase != "Running")] | length')

  if [[ "$not_ready" == "0" ]]; then
    pass "[$label] All pods Running in $ns"
  else
    local bad
    bad=$(kubectl --context "$ctx" get pods -n "$ns" -o json 2>/dev/null \
      | jq -r '.items[] | select(.status.phase != "Running") | "\(.metadata.name) (\(.status.phase))"')
    fail "[$label] $not_ready pod(s) not Running in $ns: $bad"
  fi
}

check_pod_count() {
  local ctx="$1" ns="$2" expected="$3" label="$4"
  local actual
  actual=$(kubectl --context "$ctx" get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')

  if [[ "$actual" -ge "$expected" ]]; then
    pass "[$label] $actual pods in $ns (expected >= $expected)"
  else
    fail "[$label] Only $actual pods in $ns (expected >= $expected)"
  fi
}

check_deployment_exists() {
  local ctx="$1" ns="$2" deploy="$3" label="$4"
  if kubectl --context "$ctx" get deploy "$deploy" -n "$ns" &>/dev/null; then
    pass "[$label] Deployment $deploy exists"
  else
    fail "[$label] Deployment $deploy not found in $ns"
  fi
}

check_api_responds() {
  local url="$1" label="$2"
  local status
  status=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 \
    "${url}/api/hyperfleet/v1/clusters" 2>/dev/null) || status="error"

  if [[ "$status" == "200" ]]; then
    pass "[$label] API responds (HTTP 200)"
  else
    fail "[$label] API not responding (HTTP $status)"
  fi
}

check_rabbitmq_running() {
  local ctx="$1" ns="$2" label="$3"
  local ready
  ready=$(kubectl --context "$ctx" get deploy rabbitmq -n "$ns" -o json 2>/dev/null \
    | jq -r '.status.readyReplicas // 0')

  if [[ "$ready" -ge 1 ]]; then
    pass "[$label] RabbitMQ running ($ready replica(s))"
  else
    fail "[$label] RabbitMQ not ready"
  fi
}

check_nodes_ready() {
  local ctx="$1" label="$2"
  local total ready
  total=$(kubectl --context "$ctx" get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  ready=$(kubectl --context "$ctx" get nodes -o json 2>/dev/null \
    | jq '[.items[] | select(.status.conditions[] | select(.type=="Ready" and .status=="True"))] | length')

  if [[ "$ready" == "$total" && "$total" -gt 0 ]]; then
    pass "[$label] All $total nodes Ready"
  else
    fail "[$label] $ready/$total nodes Ready"
  fi
}

# ── Reusable Test Blocks ──

test_common_infra() {
  local ctx="$1" ns="$2" label="$3" expected_pods="$4"

  check_nodes_ready "$ctx" "$label"
  check_pod_count "$ctx" "$ns" "$expected_pods" "$label"
  check_pods_running "$ctx" "$ns" "$label"
  check_rabbitmq_running "$ctx" "$ns" "$label"

  local api_url
  if api_url=$(get_api_url "$ctx" "$ns"); then
    check_api_responds "$api_url" "$label"
  else
    fail "[$label] Could not get API LoadBalancer IP for $ns"
  fi
}

test_participant_namespaces() {
  local ctx="$1" label="$2"
  local ns_count
  ns_count=$(kubectl --context "$ctx" get namespaces --no-headers 2>/dev/null \
    | awk '{print $1}' | grep -c '^hackathon-' || true)

  if [[ "$ns_count" -gt 0 ]]; then
    pass "[$label] $ns_count participant namespaces found"
  else
    fail "[$label] No participant namespaces (hackathon-*) found"
    return
  fi

  local ns_with_labels
  ns_with_labels=$(kubectl --context "$ctx" get namespaces \
    -l hackathon.hyperfleet.io/participant --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$ns_with_labels" == "0" ]]; then
    known_issue "[$label] Namespaces not labeled with hackathon.hyperfleet.io/participant (create-hackathon-env.sh only labels ServiceAccounts)"
  fi

  local sample_ns
  sample_ns=$(kubectl --context "$ctx" get namespaces --no-headers 2>/dev/null \
    | awk '{print $1}' | grep '^hackathon-' | head -1)
  if [[ -n "$sample_ns" ]]; then
    local participant="${sample_ns#hackathon-}"

    if kubectl --context "$ctx" get sa -n "$sample_ns" -l hackathon.hyperfleet.io/participant &>/dev/null; then
      pass "[$label] RBAC: ServiceAccount exists in $sample_ns"
    else
      fail "[$label] RBAC: No ServiceAccount in $sample_ns"
    fi

    if kubectl --context "$ctx" get role hackathon-participant -n "$sample_ns" &>/dev/null; then
      pass "[$label] RBAC: Role exists in $sample_ns"
    else
      fail "[$label] RBAC: No Role in $sample_ns"
    fi

    if kubectl --context "$ctx" get rolebinding "${participant}-binding" -n "$sample_ns" &>/dev/null; then
      pass "[$label] RBAC: RoleBinding exists in $sample_ns"
    else
      fail "[$label] RBAC: No RoleBinding in $sample_ns"
    fi
  fi
}

# ── Cluster 1: Dog Food ──

test_dogfood() {
  local ctx="$1"

  # ── Healthy deployment ──
  section "Cluster 1: Healthy Deployment ($NS_HEALTHY)"
  test_common_infra "$ctx" "$NS_HEALTHY" "dogfood/healthy" 8

  local api_healthy
  api_healthy=$(get_api_url "$ctx" "$NS_HEALTHY" 2>/dev/null) || true

  if [[ -n "$api_healthy" ]]; then
    # Check existing clusters
    local cluster_count
    cluster_count=$(curl -s --max-time 10 "${api_healthy}/api/hyperfleet/v1/clusters" 2>/dev/null \
      | jq '.total // 0') || cluster_count=0

    # Phase null check on existing cluster
    if [[ "$cluster_count" -gt 0 ]]; then
      local phase
      phase=$(curl -s --max-time 10 "${api_healthy}/api/hyperfleet/v1/clusters" 2>/dev/null \
        | jq -r '.items[0].status.phase // "null"')
      if [[ "$phase" == "null" || "$phase" == "" ]]; then
        known_issue "[dogfood/healthy] Cluster phase is null (Reconciled=True but phase not set)"
      else
        pass "[dogfood/healthy] Cluster phase is set: $phase"
      fi
    fi

    # Reconciliation test
    section "Cluster 1: Reconciliation Test"
    echo "  Creating test cluster: $SMOKE_CLUSTER_NAME"

    # Cleanup stale test cluster
    local stale_id
    stale_id=$(curl -s --max-time 10 \
      "${api_healthy}/api/hyperfleet/v1/clusters?name=${SMOKE_CLUSTER_NAME}" 2>/dev/null \
      | jq -r '.items[0].id // empty')
    if [[ -n "$stale_id" ]]; then
      curl -s -X DELETE --max-time 10 ${API_IDENTITY_HEADER} \
        "${api_healthy}/api/hyperfleet/v1/clusters/${stale_id}" &>/dev/null || true
      sleep 2
    fi

    # Create test cluster
    local create_status
    create_status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
      -X POST "${api_healthy}/api/hyperfleet/v1/clusters" \
      -H "Content-Type: application/json" ${API_IDENTITY_HEADER} \
      -d "{
        \"name\": \"${SMOKE_CLUSTER_NAME}\",
        \"kind\": \"Cluster\",
        \"labels\": {\"purpose\": \"smoke-test\", \"environment\": \"hackathon\"},
        \"spec\": {\"provider\": \"gcp\", \"region\": \"us-east1\"}
      }" 2>/dev/null) || create_status="error"

    if [[ "$create_status" == "201" || "$create_status" == "409" ]]; then
      pass "[dogfood/healthy] Test cluster created (HTTP $create_status)"

      # Get cluster ID
      local cluster_id
      cluster_id=$(curl -s --max-time 10 \
        "${api_healthy}/api/hyperfleet/v1/clusters?name=${SMOKE_CLUSTER_NAME}" 2>/dev/null \
        | jq -r '.items[0].id // empty')

      if [[ -n "$cluster_id" ]]; then
        # Poll for reconciliation
        local elapsed=0
        local reconciled="False"
        echo "  Waiting for reconciliation (timeout: ${RECONCILE_TIMEOUT}s)..."

        while [[ $elapsed -lt $RECONCILE_TIMEOUT ]]; do
          reconciled=$(curl -s --max-time 5 \
            "${api_healthy}/api/hyperfleet/v1/clusters/${cluster_id}" 2>/dev/null \
            | jq -r '.status.conditions[]? | select(.type=="Reconciled") | .status // "False"') || reconciled="False"

          if [[ "$reconciled" == "True" ]]; then
            break
          fi
          sleep 5
          elapsed=$((elapsed + 5))
        done

        if [[ "$reconciled" == "True" ]]; then
          pass "[dogfood/healthy] Test cluster reconciled in ${elapsed}s"
        else
          fail "[dogfood/healthy] Test cluster NOT reconciled after ${RECONCILE_TIMEOUT}s"
        fi

        # Check adapter statuses
        local adapter_count
        adapter_count=$(curl -s --max-time 10 \
          "${api_healthy}/api/hyperfleet/v1/clusters/${cluster_id}/statuses" 2>/dev/null \
          | jq '.total // 0') || adapter_count=0

        if [[ "$adapter_count" -ge 2 ]]; then
          pass "[dogfood/healthy] $adapter_count adapters reported status"
        else
          warn "[dogfood/healthy] Only $adapter_count adapters reported status (expected >= 2)"
        fi

        # Cleanup
        if [[ "$CLEANUP" == true ]]; then
          curl -s -X DELETE --max-time 10 ${API_IDENTITY_HEADER} \
            "${api_healthy}/api/hyperfleet/v1/clusters/${cluster_id}" &>/dev/null || true
          echo "  Test cluster cleaned up"
        else
          echo "  Skipping cleanup (--no-cleanup)"
        fi
      else
        fail "[dogfood/healthy] Could not retrieve test cluster ID"
      fi
    else
      fail "[dogfood/healthy] Failed to create test cluster (HTTP $create_status)"
    fi
  fi

  # ── Broken deployments (per-region) ──
  local broken_ns broken_label
  for broken_ns in "$NS_BROKEN_AMERICAS" "$NS_BROKEN_EUROPE"; do
    broken_label="dogfood/${broken_ns#hyperfleet-}"

    section "Cluster 1: Broken Deployment ($broken_ns)"
    test_common_infra "$ctx" "$broken_ns" "$broken_label" 8

    local adapter1_broken_logs
    adapter1_broken_logs=$(kubectl --context "$ctx" logs deploy/adapter1-hyperfleet-adapter \
      -n "$broken_ns" --tail=20 2>/dev/null) || adapter1_broken_logs=""

    if echo "$adapter1_broken_logs" | grep -q "clusters-BROKEN"; then
      pass "[$broken_label] adapter1 is using broken precondition URL (/clusters-BROKEN/)"
    elif echo "$adapter1_broken_logs" | grep -qi "error\|failed\|404"; then
      pass "[$broken_label] adapter1 is reporting errors (broken config active)"
    else
      fail "[$broken_label] adapter1 does not appear to be using the broken config"
    fi

    local api_broken
    api_broken=$(get_api_url "$ctx" "$broken_ns" 2>/dev/null) || true

    if [[ -n "$api_broken" ]]; then
      local total_broken
      total_broken=$(curl -s --max-time 10 "${api_broken}/api/hyperfleet/v1/clusters" 2>/dev/null \
        | jq '.total // 0') || total_broken=0

      if [[ "$total_broken" -eq 0 ]]; then
        warn "[$broken_label] No clusters in broken deployment -- run seed-hackathon-clusters.sh with --broken-${broken_ns#hyperfleet-broken-} flag"
      else
        local stuck_clusters
        stuck_clusters=$(curl -s --max-time 10 "${api_broken}/api/hyperfleet/v1/clusters" 2>/dev/null \
          | jq '[.items[] | select(
              (.status.conditions | length == 0) or
              (.status.conditions[]? | select(.type=="Reconciled" and .status!="True"))
            )] | length') || stuck_clusters=0

        if [[ "$stuck_clusters" -gt 0 ]]; then
          pass "[$broken_label] $stuck_clusters/$total_broken cluster(s) stuck (not reconciled)"
        else
          fail "[$broken_label] All $total_broken clusters are Reconciled=True -- broken deployment is not broken"
        fi
      fi
    fi
  done

  # ── Monitoring ──
  section "Cluster 1: Monitoring"

  if kubectl --context "$ctx" get namespace "$NS_MONITORING" &>/dev/null; then
    local grafana_ready
    grafana_ready=$(kubectl --context "$ctx" get pods -n "$NS_MONITORING" \
      -l app.kubernetes.io/name=grafana --no-headers 2>/dev/null | grep -c "Running" || true)

    if [[ "$grafana_ready" -ge 1 ]]; then
      pass "[dogfood/monitoring] Grafana running"
    else
      fail "[dogfood/monitoring] Grafana not running"
    fi

    local prom_ready
    prom_ready=$(kubectl --context "$ctx" get pods -n "$NS_MONITORING" \
      -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | grep -c "Running" || true)

    if [[ "$prom_ready" -ge 1 ]]; then
      pass "[dogfood/monitoring] Prometheus running"
    else
      fail "[dogfood/monitoring] Prometheus not running"
    fi
  else
    fail "[dogfood/monitoring] Namespace $NS_MONITORING not found"
  fi

  # ── Isolation ──
  section "Cluster 1: Isolation"

  local ip_healthy ip_broken_americas ip_broken_europe
  ip_healthy=$(kubectl --context "$ctx" get svc hyperfleet-api -n "$NS_HEALTHY" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null) || ip_healthy=""
  ip_broken_americas=$(kubectl --context "$ctx" get svc hyperfleet-api -n "$NS_BROKEN_AMERICAS" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null) || ip_broken_americas=""
  ip_broken_europe=$(kubectl --context "$ctx" get svc hyperfleet-api -n "$NS_BROKEN_EUROPE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null) || ip_broken_europe=""

  local all_ips_unique=true
  if [[ -z "$ip_healthy" || -z "$ip_broken_americas" || -z "$ip_broken_europe" ]]; then
    fail "[dogfood] Could not determine API IPs for isolation check"
    all_ips_unique=false
  else
    if [[ "$ip_healthy" == "$ip_broken_americas" || "$ip_healthy" == "$ip_broken_europe" ]]; then
      fail "[dogfood] Healthy shares API IP with a broken deployment -- not isolated"
      all_ips_unique=false
    fi
    if [[ "$ip_broken_americas" == "$ip_broken_europe" ]]; then
      fail "[dogfood] Broken Americas and Europe share the same API IP -- not isolated"
      all_ips_unique=false
    fi
  fi

  if [[ "$all_ips_unique" == true ]]; then
    pass "[dogfood] All 3 deployments have different API IPs (healthy=$ip_healthy, americas=$ip_broken_americas, europe=$ip_broken_europe)"
  fi
}

# ── Cluster 2: Build ──

test_build() {
  local ctx="$1"

  section "Cluster 2: Infrastructure"
  test_common_infra "$ctx" "$NS_HYPERFLEET" "build" 5

  # Verify no adapters
  local adapter_count
  adapter_count=$(kubectl --context "$ctx" get deploy -n "$NS_HYPERFLEET" --no-headers 2>/dev/null \
    | grep -c "adapter" || true)

  if [[ "$adapter_count" == "0" ]]; then
    pass "[build] No adapter deployments (correct for Scenario 4)"
  else
    fail "[build] Found $adapter_count adapter deployment(s) -- Build cluster should have none"
  fi

  # Participant namespaces
  section "Cluster 2: Participant Namespaces"
  test_participant_namespaces "$ctx" "build"
}

# ── Cluster 3: Operate ──

test_operate() {
  local ctx="$1"

  section "Cluster 3: Infrastructure"
  test_common_infra "$ctx" "$NS_HYPERFLEET" "operate" 8

  # Seeded clusters
  section "Cluster 3: Seeded Clusters"

  local api_operate
  api_operate=$(get_api_url "$ctx" "$NS_HYPERFLEET" 2>/dev/null) || true

  if [[ -n "$api_operate" ]]; then
    local total_clusters
    total_clusters=$(curl -s --max-time 10 "${api_operate}/api/hyperfleet/v1/clusters" 2>/dev/null \
      | jq '.total // 0') || total_clusters=0

    if [[ "$total_clusters" -ge 12 ]]; then
      pass "[operate] $total_clusters seeded clusters found (expected >= 12)"
    else
      fail "[operate] Only $total_clusters seeded clusters (expected >= 12)"
    fi

    # Region distribution
    local us_east us_west eu_west
    us_east=$(curl -s --max-time 10 "${api_operate}/api/hyperfleet/v1/clusters" 2>/dev/null \
      | jq '[.items[] | select(.labels.region == "us-east")] | length') || us_east=0
    us_west=$(curl -s --max-time 10 "${api_operate}/api/hyperfleet/v1/clusters" 2>/dev/null \
      | jq '[.items[] | select(.labels.region == "us-west")] | length') || us_west=0
    eu_west=$(curl -s --max-time 10 "${api_operate}/api/hyperfleet/v1/clusters" 2>/dev/null \
      | jq '[.items[] | select(.labels.region == "eu-west")] | length') || eu_west=0

    if [[ "$us_east" -eq 4 && "$us_west" -eq 4 && "$eu_west" -eq 4 ]]; then
      pass "[operate] Region distribution correct: us-east=$us_east, us-west=$us_west, eu-west=$eu_west"
    else
      fail "[operate] Region distribution wrong: us-east=$us_east, us-west=$us_west, eu-west=$eu_west (expected 4/4/4)"
    fi
  else
    fail "[operate] Could not get API URL"
  fi

  # Sentinel activity
  section "Cluster 3: Sentinel Activity"

  local sentinel_logs
  sentinel_logs=$(kubectl --context "$ctx" logs deploy/clusters-hyperfleet-sentinel \
    -n "$NS_HYPERFLEET" --since=5m --tail=5 2>/dev/null) || sentinel_logs=""

  if [[ -n "$sentinel_logs" ]]; then
    pass "[operate] Sentinel has recent activity (last 5 min)"
  else
    warn "[operate] No sentinel logs in the last 5 minutes"
  fi

  # Participant namespaces
  section "Cluster 3: Participant Namespaces"
  test_participant_namespaces "$ctx" "operate"
}

# ── Summary ──

print_summary() {
  echo ""
  echo "════════════════════════════════════════════"
  echo "  HACKATHON SMOKE TEST SUMMARY"
  echo "════════════════════════════════════════════"
  echo "  PASS:          $PASS_COUNT"
  echo "  FAIL:          $FAIL_COUNT"
  echo "  WARN:          $WARN_COUNT"
  echo "  KNOWN ISSUES:  $KNOWN_COUNT"
  echo "════════════════════════════════════════════"

  if [[ $FAIL_COUNT -eq 0 ]]; then
    echo "  VERDICT:  READY"
  else
    echo "  VERDICT:  NOT READY  ($FAIL_COUNT failure(s))"
    echo ""
    echo "  Failures:"
    for f in "${FAILURES[@]}"; do
      echo "    - $f"
    done
  fi

  echo "════════════════════════════════════════════"
  echo ""
}

# ── Main ──

main() {
  parse_args "$@"
  check_prereqs

  echo "HyperFleet Ignition Day — Smoke Test"
  date '+%Y-%m-%d %H:%M:%S'

  if [[ "$CLUSTER_FILTER" == "all" || "$CLUSTER_FILTER" == "dogfood" ]]; then
    section "CLUSTER 1: DOG FOOD"
    if check_context "$CTX_DOGFOOD" "dogfood"; then
      test_dogfood "$CTX_DOGFOOD"
    fi
  fi

  if [[ "$CLUSTER_FILTER" == "all" || "$CLUSTER_FILTER" == "build" ]]; then
    section "CLUSTER 2: BUILD"
    if check_context "$CTX_BUILD" "build"; then
      test_build "$CTX_BUILD"
    fi
  fi

  if [[ "$CLUSTER_FILTER" == "all" || "$CLUSTER_FILTER" == "operate" ]]; then
    section "CLUSTER 3: OPERATE"
    if check_context "$CTX_OPERATE" "operate"; then
      test_operate "$CTX_OPERATE"
    fi
  fi

  print_summary

  if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
  fi
}

main "$@"
