#!/usr/bin/env bash
# Scenario validation tests for HyperFleet Ignition Day.
# Tests the user journey for Scenarios 1, 2, and 3 against live hackathon clusters.
#
# Complements smoke-test-hackathon.sh (infrastructure health) with functional checks:
#   Scenario 1: API surface, cluster lifecycle, Day-2 ops, validation, burst creation
#   Scenario 2: Reconciliation loop observability (sentinel, broker, adapters, status)
#   Scenario 3: Broken deployment debugging (stuck clusters, broken adapter behaviour)
#
# Usage: ./scripts/scenario-test-hackathon.sh [--scenario 1|2|3|all] [--no-cleanup] [--timeout N]

set -uo pipefail

# ── Constants ──

CTX_DOGFOOD="gke_hcm-hyperfleet_us-central1-a_hyperfleet-dev-hackathon-dogfood"
NS_HEALTHY="hyperfleet-healthy"
NS_BROKEN="hyperfleet-broken"

API_PORT=8000
RECONCILE_TIMEOUT=120
DATE_SUFFIX=$(date +%Y%m%d%H%M)

# ── State ──

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
FAILURES=()
SCENARIO_FILTER="all"
CLEANUP=true

# ── Argument Parsing ──

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario)
      SCENARIO_FILTER="$2"
      shift 2
      ;;
    --no-cleanup)
      CLEANUP=false
      shift
      ;;
    --timeout)
      RECONCILE_TIMEOUT="$2"
      shift 2
      ;;
    *)
      echo "Usage: $0 [--scenario 1|2|3|all] [--no-cleanup] [--timeout N]"
      exit 1
      ;;
  esac
done

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

  if ! kubectl config get-contexts "$CTX_DOGFOOD" &>/dev/null; then
    echo "ERROR: kubectl context not found: $CTX_DOGFOOD"
    echo "Run: gcloud container clusters get-credentials hyperfleet-dev-hackathon-dogfood --zone us-central1-a --project hcm-hyperfleet"
    exit 1
  fi
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

# Create a cluster and print its ID. Returns 0 on success.
create_cluster() {
  local api_url="$1" name="$2"
  local response status_code body

  response=$(curl -sS -w "\n%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    "${api_url}/api/hyperfleet/v1/clusters" \
    -d "{\"name\":\"${name}\",\"kind\":\"Cluster\",\"spec\":{\"provider\":\"gcp\",\"region\":\"us-central1\"}}" \
    --connect-timeout 5 --max-time 15 2>/dev/null)

  status_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | head -1)

  if [[ "$status_code" == "201" ]]; then
    echo "$body" | jq -r '.id'
    return 0
  fi
  return 1
}

# Poll until Reconciled=True or timeout. Prints elapsed seconds on success.
wait_reconciled() {
  local api_url="$1" cluster_id="$2" timeout="${3:-$RECONCILE_TIMEOUT}"
  local elapsed=0 status

  while [[ $elapsed -lt $timeout ]]; do
    status=$(curl -s --max-time 5 \
      "${api_url}/api/hyperfleet/v1/clusters/${cluster_id}" 2>/dev/null \
      | jq -r '.status.conditions[]? | select(.type=="Reconciled") | .status // "False"') || status="False"

    if [[ "$status" == "True" ]]; then
      echo "$elapsed"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  return 1
}

# Poll until cluster returns HTTP 404 (fully deleted) or timeout.
wait_deleted() {
  local api_url="$1" cluster_id="$2" timeout="${3:-$RECONCILE_TIMEOUT}"
  local elapsed=0 http_code

  while [[ $elapsed -lt $timeout ]]; do
    http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
      "${api_url}/api/hyperfleet/v1/clusters/${cluster_id}" 2>/dev/null) || http_code="error"

    if [[ "$http_code" == "404" ]]; then
      echo "$elapsed"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  return 1
}

# Clean up a cluster (soft delete + wait for removal). Silent on failure.
cleanup_cluster() {
  local api_url="$1" cluster_id="$2"
  curl -s -o /dev/null -X DELETE --max-time 5 \
    "${api_url}/api/hyperfleet/v1/clusters/${cluster_id}" 2>/dev/null || true
}

# Remove stale test clusters from previous runs
cleanup_stale() {
  local api_url="$1" prefix="$2"
  local ids
  ids=$(curl -s --max-time 10 "${api_url}/api/hyperfleet/v1/clusters?size=50" 2>/dev/null \
    | jq -r ".items[]? | select(.name | startswith(\"${prefix}\")) | .id" 2>/dev/null) || true

  for id in $ids; do
    cleanup_cluster "$api_url" "$id"
  done

  # Wait briefly for deletions to process
  if [[ -n "$ids" ]]; then
    sleep 10
  fi
}

# ── Scenario 1: First Cluster, Fresh Eyes ──

test_scenario_1() {
  local api_url
  api_url=$(get_api_url "$CTX_DOGFOOD" "$NS_HEALTHY") || {
    fail "[S1] Could not get API LoadBalancer IP for $NS_HEALTHY"
    return
  }

  section "Scenario 1: First Cluster, Fresh Eyes"
  echo "  API: $api_url"

  # Clean up stale test clusters
  cleanup_stale "$api_url" "scenario1-"

  # ── Cluster creation and reconciliation ──

  section "S1: Cluster Creation & Reconciliation"

  local cluster_id
  cluster_id=$(create_cluster "$api_url" "scenario1-test-${DATE_SUFFIX}") || true

  if [[ -n "$cluster_id" ]]; then
    pass "[S1] Cluster created (HTTP 201, id=${cluster_id:0:12}...)"
  else
    fail "[S1] Failed to create cluster"
    return
  fi

  # Check initial status
  local initial_reconciled
  initial_reconciled=$(curl -s --max-time 5 \
    "${api_url}/api/hyperfleet/v1/clusters/${cluster_id}" 2>/dev/null \
    | jq -r '.status.conditions[]? | select(.type=="Reconciled") | .status // "unknown"') || initial_reconciled="unknown"

  if [[ "$initial_reconciled" == "False" ]]; then
    pass "[S1] Initial status Reconciled=False (expected)"
  else
    warn "[S1] Initial status Reconciled=${initial_reconciled} (expected False, may have reconciled instantly)"
  fi

  # Wait for reconciliation
  local elapsed
  if elapsed=$(wait_reconciled "$api_url" "$cluster_id"); then
    pass "[S1] Cluster reconciled in ${elapsed}s"
  else
    fail "[S1] Cluster NOT reconciled after ${RECONCILE_TIMEOUT}s"
    [[ "$CLEANUP" == true ]] && cleanup_cluster "$api_url" "$cluster_id"
    return
  fi

  # Check adapter conditions
  local condition_count
  condition_count=$(curl -s --max-time 5 \
    "${api_url}/api/hyperfleet/v1/clusters/${cluster_id}" 2>/dev/null \
    | jq '[.status.conditions[]? | select(.type | test("Adapter.*Successful"))] | length') || condition_count=0

  if [[ "$condition_count" -ge 2 ]]; then
    pass "[S1] Both adapter conditions present ($condition_count found)"
  else
    fail "[S1] Expected >= 2 adapter conditions, found $condition_count"
  fi

  # ── Day-2 operations ──

  section "S1: Day-2 Operations"

  # PATCH cluster
  local new_gen
  new_gen=$(curl -s -X PATCH -H "Content-Type: application/json" --max-time 5 \
    "${api_url}/api/hyperfleet/v1/clusters/${cluster_id}" \
    -d '{"labels":{"team":"platform","env":"staging"}}' 2>/dev/null \
    | jq -r '.generation // 0') || new_gen=0

  if [[ "$new_gen" -ge 2 ]]; then
    pass "[S1] PATCH: generation incremented to $new_gen"
  else
    fail "[S1] PATCH: generation did not increment (got $new_gen)"
  fi

  # Wait for re-reconciliation at new generation
  if elapsed=$(wait_reconciled "$api_url" "$cluster_id" 60); then
    pass "[S1] Re-reconciled after PATCH in ${elapsed}s"
  else
    fail "[S1] NOT re-reconciled after PATCH within 60s"
  fi

  # Create node pool
  local np_status
  np_status=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Content-Type: application/json" --max-time 10 \
    "${api_url}/api/hyperfleet/v1/clusters/${cluster_id}/nodepools" \
    -d '{"name":"test-pool","kind":"NodePool","spec":{"instance_type":"e2-standard-4","replicas":3}}' 2>/dev/null)

  if [[ "$np_status" == "201" ]]; then
    pass "[S1] Node pool created (HTTP 201)"
  else
    fail "[S1] Node pool creation failed (HTTP $np_status)"
  fi

  # List node pools
  local np_count
  np_count=$(curl -s --max-time 5 \
    "${api_url}/api/hyperfleet/v1/clusters/${cluster_id}/nodepools" 2>/dev/null \
    | jq '.total // 0') || np_count=0

  if [[ "$np_count" -ge 1 ]]; then
    pass "[S1] Node pools listed ($np_count found)"
  else
    fail "[S1] No node pools found after creation"
  fi

  # ── API validation ──

  section "S1: API Validation"

  # Duplicate name
  local dup_status
  dup_status=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Content-Type: application/json" --max-time 5 \
    "${api_url}/api/hyperfleet/v1/clusters" \
    -d "{\"name\":\"scenario1-test-${DATE_SUFFIX}\",\"kind\":\"Cluster\",\"spec\":{\"provider\":\"gcp\"}}" 2>/dev/null)

  if [[ "$dup_status" == "409" ]]; then
    pass "[S1] Duplicate name returns HTTP 409"
  else
    fail "[S1] Duplicate name returned HTTP $dup_status (expected 409)"
  fi

  # Missing kind
  local kind_status
  kind_status=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Content-Type: application/json" --max-time 5 \
    "${api_url}/api/hyperfleet/v1/clusters" \
    -d '{"name":"no-kind","spec":{"provider":"gcp"}}' 2>/dev/null)

  if [[ "$kind_status" == "400" ]]; then
    pass "[S1] Missing kind returns HTTP 400"
  else
    fail "[S1] Missing kind returned HTTP $kind_status (expected 400)"
  fi

  # Invalid name
  local invalid_status
  invalid_status=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Content-Type: application/json" --max-time 5 \
    "${api_url}/api/hyperfleet/v1/clusters" \
    -d '{"name":"INVALID!@#","kind":"Cluster","spec":{"provider":"gcp"}}' 2>/dev/null)

  if [[ "$invalid_status" == "400" ]]; then
    pass "[S1] Invalid name returns HTTP 400"
  else
    fail "[S1] Invalid name returned HTTP $invalid_status (expected 400)"
  fi

  # Non-existent cluster
  local notfound_status
  notfound_status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    "${api_url}/api/hyperfleet/v1/clusters/00000000-0000-0000-0000-000000000000" 2>/dev/null)

  if [[ "$notfound_status" == "404" ]]; then
    pass "[S1] Non-existent cluster returns HTTP 404"
  else
    fail "[S1] Non-existent cluster returned HTTP $notfound_status (expected 404)"
  fi

  # ── Delete lifecycle ──

  section "S1: Delete Lifecycle"

  local delete_gen
  delete_gen=$(curl -s -X DELETE --max-time 5 \
    "${api_url}/api/hyperfleet/v1/clusters/${cluster_id}" 2>/dev/null \
    | jq -r '.generation // 0') || delete_gen=0

  if [[ "$delete_gen" -ge 3 ]]; then
    pass "[S1] DELETE: generation incremented to $delete_gen"
  else
    fail "[S1] DELETE: generation did not increment (got $delete_gen)"
  fi

  if elapsed=$(wait_deleted "$api_url" "$cluster_id"); then
    pass "[S1] Cluster fully removed in ${elapsed}s"
  else
    fail "[S1] Cluster NOT fully removed after ${RECONCILE_TIMEOUT}s"
  fi

  # ── Burst test ──

  section "S1: Burst Creation (5 simultaneous)"

  local burst_ids=()
  local burst_ok=0

  for i in $(seq 1 5); do
    local bid
    bid=$(create_cluster "$api_url" "scenario1-burst-${i}-${DATE_SUFFIX}") || true
    if [[ -n "$bid" ]]; then
      burst_ids+=("$bid")
      burst_ok=$((burst_ok + 1))
    fi
  done

  if [[ "$burst_ok" -eq 5 ]]; then
    pass "[S1] Burst: all 5 clusters created (HTTP 201)"
  else
    fail "[S1] Burst: only $burst_ok/5 clusters created"
  fi

  # Wait for all to reconcile
  local burst_reconciled=0
  for bid in "${burst_ids[@]}"; do
    if wait_reconciled "$api_url" "$bid" >/dev/null; then
      burst_reconciled=$((burst_reconciled + 1))
    fi
  done

  if [[ "$burst_reconciled" -eq "${#burst_ids[@]}" ]]; then
    pass "[S1] Burst: all $burst_reconciled clusters reconciled"
  else
    fail "[S1] Burst: only $burst_reconciled/${#burst_ids[@]} clusters reconciled"
  fi

  # Cleanup burst clusters
  if [[ "$CLEANUP" == true ]]; then
    for bid in "${burst_ids[@]}"; do
      cleanup_cluster "$api_url" "$bid"
    done
    echo "  Burst clusters cleaned up"
  fi
}

# ── Scenario 2: The Reconciliation Loop ──

test_scenario_2() {
  local api_url
  api_url=$(get_api_url "$CTX_DOGFOOD" "$NS_HEALTHY") || {
    fail "[S2] Could not get API LoadBalancer IP for $NS_HEALTHY"
    return
  }

  section "Scenario 2: The Reconciliation Loop"
  echo "  API: $api_url"

  # Clean up stale test clusters
  cleanup_stale "$api_url" "scenario2-"

  # ── Pipeline component health ──

  section "S2: Pipeline Components"

  # Sentinel
  local sentinel_ready
  sentinel_ready=$(kubectl --context "$CTX_DOGFOOD" get deploy clusters-hyperfleet-sentinel \
    -n "$NS_HEALTHY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null) || sentinel_ready=0

  if [[ "$sentinel_ready" -ge 1 ]]; then
    pass "[S2] Sentinel running ($sentinel_ready replica(s))"
  else
    fail "[S2] Sentinel not ready"
  fi

  # RabbitMQ
  local rabbitmq_ready
  rabbitmq_ready=$(kubectl --context "$CTX_DOGFOOD" get deploy rabbitmq \
    -n "$NS_HEALTHY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null) || rabbitmq_ready=0

  if [[ "$rabbitmq_ready" -ge 1 ]]; then
    pass "[S2] RabbitMQ running ($rabbitmq_ready replica(s))"
  else
    fail "[S2] RabbitMQ not ready"
  fi

  # Adapter1
  local adapter1_ready
  adapter1_ready=$(kubectl --context "$CTX_DOGFOOD" get deploy adapter1-hyperfleet-adapter \
    -n "$NS_HEALTHY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null) || adapter1_ready=0

  if [[ "$adapter1_ready" -ge 1 ]]; then
    pass "[S2] Adapter1 running ($adapter1_ready replica(s))"
  else
    fail "[S2] Adapter1 not ready"
  fi

  # Adapter2
  local adapter2_ready
  adapter2_ready=$(kubectl --context "$CTX_DOGFOOD" get deploy adapter2-hyperfleet-adapter \
    -n "$NS_HEALTHY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null) || adapter2_ready=0

  if [[ "$adapter2_ready" -ge 1 ]]; then
    pass "[S2] Adapter2 running ($adapter2_ready replica(s))"
  else
    fail "[S2] Adapter2 not ready"
  fi

  # ── Full reconciliation loop ──

  section "S2: Full Reconciliation Loop"

  local cluster_id
  cluster_id=$(create_cluster "$api_url" "scenario2-test-${DATE_SUFFIX}") || true

  if [[ -n "$cluster_id" ]]; then
    pass "[S2] Cluster created for loop test (id=${cluster_id:0:12}...)"
  else
    fail "[S2] Failed to create cluster for loop test"
    return
  fi

  # Wait for reconciliation (proves: sentinel detected -> broker delivered -> adapters processed -> status reported -> reconciled)
  local elapsed
  if elapsed=$(wait_reconciled "$api_url" "$cluster_id"); then
    pass "[S2] Full reconciliation loop completed in ${elapsed}s"
  else
    fail "[S2] Reconciliation loop did NOT complete after ${RECONCILE_TIMEOUT}s"
    [[ "$CLEANUP" == true ]] && cleanup_cluster "$api_url" "$cluster_id"
    return
  fi

  # ── Adapter status verification ──

  section "S2: Adapter Status Reports"

  local statuses
  statuses=$(curl -s --max-time 5 \
    "${api_url}/api/hyperfleet/v1/clusters/${cluster_id}/statuses" 2>/dev/null)

  local status_count
  status_count=$(echo "$statuses" | jq '.total // 0') || status_count=0

  if [[ "$status_count" -ge 2 ]]; then
    pass "[S2] $status_count adapter status reports received"
  else
    fail "[S2] Only $status_count adapter reports (expected >= 2)"
  fi

  # Check Applied=True for all adapters
  local applied_true
  applied_true=$(echo "$statuses" | jq '[.items[]? | .conditions[]? | select(.type=="Applied" and .status=="True")] | length') || applied_true=0

  if [[ "$applied_true" -ge 2 ]]; then
    pass "[S2] All adapters report Applied=True ($applied_true)"
  else
    fail "[S2] Only $applied_true adapters report Applied=True (expected >= 2)"
  fi

  # Check Available=True for all adapters
  local available_true
  available_true=$(echo "$statuses" | jq '[.items[]? | .conditions[]? | select(.type=="Available" and .status=="True")] | length') || available_true=0

  if [[ "$available_true" -ge 2 ]]; then
    pass "[S2] All adapters report Available=True ($available_true)"
  else
    fail "[S2] Only $available_true adapters report Available=True (expected >= 2)"
  fi

  # Check Health=True for all adapters
  local health_true
  health_true=$(echo "$statuses" | jq '[.items[]? | .conditions[]? | select(.type=="Health" and .status=="True")] | length') || health_true=0

  if [[ "$health_true" -ge 2 ]]; then
    pass "[S2] All adapters report Health=True ($health_true)"
  else
    fail "[S2] Only $health_true adapters report Health=True (expected >= 2)"
  fi

  # Cleanup
  if [[ "$CLEANUP" == true ]]; then
    cleanup_cluster "$api_url" "$cluster_id"
    echo "  Test cluster cleaned up"
  fi
}

# ── Scenario 3: Something Is Wrong ──

test_scenario_3() {
  local api_url
  api_url=$(get_api_url "$CTX_DOGFOOD" "$NS_BROKEN") || {
    fail "[S3] Could not get API LoadBalancer IP for $NS_BROKEN"
    return
  }

  section "Scenario 3: Something Is Wrong"
  echo "  API: $api_url"

  # ── Broken adapter verification ──

  section "S3: Broken Adapter"

  # Adapter1 pod running
  local adapter1_ready
  adapter1_ready=$(kubectl --context "$CTX_DOGFOOD" get deploy adapter1-hyperfleet-adapter \
    -n "$NS_BROKEN" -o jsonpath='{.status.readyReplicas}' 2>/dev/null) || adapter1_ready=0

  if [[ "$adapter1_ready" -ge 1 ]]; then
    pass "[S3] Broken adapter1 pod running"
  else
    fail "[S3] Broken adapter1 pod not ready"
  fi

  # Verify adapter1 is using the broken config by checking the configmap
  local configmap_data
  configmap_data=$(kubectl --context "$CTX_DOGFOOD" get configmap adapter1-hyperfleet-adapter-config \
    -n "$NS_BROKEN" -o jsonpath='{.data.adapter-config\.yaml}' 2>/dev/null) || configmap_data=""

  if echo "$configmap_data" | grep -q "adapter1" 2>/dev/null; then
    pass "[S3] Adapter1 config deployed"
  else
    warn "[S3] Could not verify adapter1 config content"
  fi

  # Verify broken task config is active by checking the task configmap for the broken URL
  local task_config_data
  task_config_data=$(kubectl --context "$CTX_DOGFOOD" get configmap adapter1-hyperfleet-adapter-task \
    -n "$NS_BROKEN" -o jsonpath='{.data.task-config\.yaml}' 2>/dev/null) || task_config_data=""

  if echo "$task_config_data" | grep -q "clusters-BROKEN" 2>/dev/null; then
    pass "[S3] Broken precondition URL (/clusters-BROKEN/) active in task config"
  else
    fail "[S3] Broken precondition URL not found in task config"
  fi

  # ── Pre-seeded stuck clusters ──

  section "S3: Pre-seeded Stuck Clusters"

  local total_broken
  total_broken=$(curl -s --max-time 5 "${api_url}/api/hyperfleet/v1/clusters" 2>/dev/null \
    | jq '.total // 0') || total_broken=0

  if [[ "$total_broken" -ge 2 ]]; then
    pass "[S3] Pre-seeded clusters exist ($total_broken found)"
  else
    fail "[S3] Expected >= 2 pre-seeded clusters, found $total_broken"
  fi

  # Check they are stuck (Reconciled=False)
  local stuck_count
  stuck_count=$(curl -s --max-time 5 "${api_url}/api/hyperfleet/v1/clusters" 2>/dev/null \
    | jq '[.items[]? | select(.status.conditions[]? | select(.type=="Reconciled" and .status=="False"))] | length') || stuck_count=0

  if [[ "$stuck_count" -ge 2 ]]; then
    pass "[S3] $stuck_count clusters stuck at Reconciled=False"
  else
    fail "[S3] Only $stuck_count clusters stuck (expected >= 2)"
  fi

  # ── New cluster stays stuck ──

  section "S3: New Cluster Stays Stuck"

  # Clean up stale test clusters
  cleanup_stale "$api_url" "scenario3-"

  local broken_id
  broken_id=$(create_cluster "$api_url" "scenario3-test-${DATE_SUFFIX}") || true

  if [[ -n "$broken_id" ]]; then
    pass "[S3] Test cluster created on broken API (id=${broken_id:0:12}...)"
  else
    fail "[S3] Failed to create test cluster on broken API"
    return
  fi

  # Wait 30s and verify it stays stuck
  echo "  Waiting 30s to confirm cluster stays stuck..."
  sleep 30

  local broken_reconciled
  broken_reconciled=$(curl -s --max-time 5 \
    "${api_url}/api/hyperfleet/v1/clusters/${broken_id}" 2>/dev/null \
    | jq -r '.status.conditions[]? | select(.type=="Reconciled") | .status // "unknown"') || broken_reconciled="unknown"

  if [[ "$broken_reconciled" == "False" ]]; then
    pass "[S3] Test cluster stays Reconciled=False after 30s (stuck as expected)"
  else
    fail "[S3] Test cluster is Reconciled=$broken_reconciled (expected False, should be stuck)"
  fi

  # ── Status observability ──

  section "S3: Status Observability"

  local broken_statuses
  broken_statuses=$(curl -s --max-time 5 \
    "${api_url}/api/hyperfleet/v1/clusters/${broken_id}/statuses" 2>/dev/null)

  local broken_status_count
  broken_status_count=$(echo "$broken_statuses" | jq '.total // 0') || broken_status_count=0

  # adapter1 should be reporting failure or not reporting at all
  # When the precondition fails, adapter1 never reaches post-actions and may not report status
  local adapter1_reported
  adapter1_reported=$(echo "$broken_statuses" \
    | jq '[.items[]? | select(.adapter=="adapter1")] | length') || adapter1_reported=0

  if [[ "$adapter1_reported" -eq 0 ]]; then
    pass "[S3] Adapter1 has not reported status (broken precondition prevents reporting)"
  else
    local adapter1_health
    adapter1_health=$(echo "$broken_statuses" \
      | jq -r '.items[]? | select(.adapter=="adapter1") | .conditions[]? | select(.type=="Health") | .status // "unknown"') || adapter1_health="unknown"
    if [[ "$adapter1_health" == "False" || "$adapter1_health" == "Unknown" ]]; then
      pass "[S3] Adapter1 reports Health=$adapter1_health (broken as expected)"
    else
      fail "[S3] Adapter1 reports Health=$adapter1_health (expected False, Unknown, or no report)"
    fi
  fi

  # adapter2 should still be reporting normally
  local adapter2_available
  adapter2_available=$(echo "$broken_statuses" \
    | jq -r '.items[]? | select(.adapter=="adapter2") | .conditions[]? | select(.type=="Available") | .status // "missing"') || adapter2_available="missing"

  if [[ "$adapter2_available" == "True" ]]; then
    pass "[S3] Adapter2 still reports Available=True (not broken)"
  elif [[ "$adapter2_available" == "missing" ]]; then
    warn "[S3] Adapter2 status not yet reported (may need more time)"
  else
    warn "[S3] Adapter2 reports Available=$adapter2_available"
  fi

  # Cleanup test cluster (leave pre-seeded ones)
  if [[ "$CLEANUP" == true ]]; then
    cleanup_cluster "$api_url" "$broken_id"
    echo "  Test cluster cleaned up (pre-seeded stuck clusters preserved)"
  fi
}

# ── Main ──

echo "════════════════════════════════════════════"
echo "  HACKATHON SCENARIO TESTS"
echo "════════════════════════════════════════════"
echo "  Timeout: ${RECONCILE_TIMEOUT}s"
echo "  Cleanup: ${CLEANUP}"
echo "  Scenarios: ${SCENARIO_FILTER}"

check_prereqs

case "$SCENARIO_FILTER" in
  1)   test_scenario_1 ;;
  2)   test_scenario_2 ;;
  3)   test_scenario_3 ;;
  all)
    test_scenario_1
    test_scenario_2
    test_scenario_3
    ;;
  *)
    echo "ERROR: invalid scenario: $SCENARIO_FILTER (valid: 1, 2, 3, all)"
    exit 1
    ;;
esac

# ── Summary ──

echo ""
echo "════════════════════════════════════════════"
echo "  SCENARIO TEST SUMMARY"
echo "════════════════════════════════════════════"
echo "  PASS:  $PASS_COUNT"
echo "  FAIL:  $FAIL_COUNT"
echo "  WARN:  $WARN_COUNT"
echo "════════════════════════════════════════════"

if [[ $FAIL_COUNT -eq 0 ]]; then
  echo "  VERDICT:  ALL SCENARIOS READY"
else
  echo "  VERDICT:  ISSUES FOUND"
  echo ""
  echo "  Failures:"
  for f in "${FAILURES[@]}"; do
    echo "    - $f"
  done
fi

echo ""
exit "$FAIL_COUNT"
