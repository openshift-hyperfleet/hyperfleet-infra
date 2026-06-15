#!/usr/bin/env bash
# Scenario validation tests for HyperFleet Ignition Day.
# Tests the user journey for Scenarios 1-5 against live hackathon clusters.
#
# Complements smoke-test-hackathon.sh (infrastructure health) with functional checks:
#   Scenario 1: API surface, cluster lifecycle, Day-2 ops, validation, burst creation
#   Scenario 2: Reconciliation loop observability (sentinel, broker, adapters, status)
#   Scenario 3: Broken deployment debugging (stuck clusters, broken adapter behaviour)
#   Scenario 4: Build Your Own Adapter (deploy test adapter, verify reconciliation loop)
#   Scenario 5: Shard the Sentinel (deploy regional sentinel, verify selective polling)
#
# Usage: ./scripts/scenario-test-hackathon.sh [--scenario 1|2|3|4|5|all] [--no-cleanup] [--timeout N] [--namespace NS]

set -uo pipefail

# ── Constants ──

CTX_DOGFOOD="gke_hcm-hyperfleet_us-central1-a_hyperfleet-dev-hackathon-dogfood"
CTX_BUILD="gke_hcm-hyperfleet_us-central1-a_hyperfleet-dev-hackathon-build"
CTX_OPERATE="gke_hcm-hyperfleet_us-central1-a_hyperfleet-dev-hackathon-operate"
NS_HEALTHY="hyperfleet-healthy"
NS_BROKEN_AMERICAS="hyperfleet-broken-americas"
NS_BROKEN_EUROPE="hyperfleet-broken-europe"
NS_HYPERFLEET="hyperfleet"

API_IDENTITY_HEADER="-H X-HyperFleet-Identity:scenario-test@redhat.com"
API_PORT=8000
RECONCILE_TIMEOUT=120
DATE_SUFFIX=$(date +%Y%m%d%H%M)
PARTICIPANT_NS_OVERRIDE=""

# Path to test adapter configs (relative to repo root)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ADAPTER_CONFIGS="${REPO_ROOT}/helmfile/configs/hackathon/adapters/test-adapter"

# ── State ──

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
FAILURES=()
SCENARIO_FILTER="all"
REGION_FILTER="all"
CLEANUP=true

# ── Argument Parsing ──

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario)
      SCENARIO_FILTER="$2"
      shift 2
      ;;
    --region)
      REGION_FILTER="$2"
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
    --namespace)
      PARTICIPANT_NS_OVERRIDE="$2"
      shift 2
      ;;
    *)
      echo "Usage: $0 [--scenario 1|2|3|4|5|all] [--region americas|europe|all] [--no-cleanup] [--timeout N] [--namespace NS]"
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
    -H "Content-Type: application/json" ${API_IDENTITY_HEADER} \
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
  curl -s -o /dev/null -X DELETE --max-time 5 ${API_IDENTITY_HEADER} \
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
  new_gen=$(curl -s -X PATCH -H "Content-Type: application/json" ${API_IDENTITY_HEADER} --max-time 5 \
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
    -H "Content-Type: application/json" ${API_IDENTITY_HEADER} --max-time 10 \
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
    -H "Content-Type: application/json" ${API_IDENTITY_HEADER} --max-time 5 \
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
    -H "Content-Type: application/json" ${API_IDENTITY_HEADER} --max-time 5 \
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
    -H "Content-Type: application/json" ${API_IDENTITY_HEADER} --max-time 5 \
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
  delete_gen=$(curl -s -X DELETE ${API_IDENTITY_HEADER} --max-time 5 \
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

# Runs Scenario 3 tests against a specific broken namespace.
# $1: namespace (e.g., hyperfleet-broken-americas)
# $2: region label for output (e.g., americas)
_test_scenario_3_region() {
  local ns_broken="$1" region="$2"
  local tag="S3/${region}"

  local api_url
  api_url=$(get_api_url "$CTX_DOGFOOD" "$ns_broken") || {
    fail "[$tag] Could not get API LoadBalancer IP for $ns_broken"
    return
  }

  section "Scenario 3: Something Is Wrong ($region)"
  echo "  API: $api_url"
  echo "  Namespace: $ns_broken"

  # ── Broken adapter verification ──

  section "$tag: Broken Adapter"

  local adapter1_ready
  adapter1_ready=$(kubectl --context "$CTX_DOGFOOD" get deploy adapter1-hyperfleet-adapter \
    -n "$ns_broken" -o jsonpath='{.status.readyReplicas}' 2>/dev/null) || adapter1_ready=0

  if [[ "$adapter1_ready" -ge 1 ]]; then
    pass "[$tag] Broken adapter1 pod running"
  else
    fail "[$tag] Broken adapter1 pod not ready"
  fi

  local configmap_data
  configmap_data=$(kubectl --context "$CTX_DOGFOOD" get configmap adapter1-hyperfleet-adapter-config \
    -n "$ns_broken" -o jsonpath='{.data.adapter-config\.yaml}' 2>/dev/null) || configmap_data=""

  if echo "$configmap_data" | grep -q "adapter1" 2>/dev/null; then
    pass "[$tag] Adapter1 config deployed"
  else
    warn "[$tag] Could not verify adapter1 config content"
  fi

  local task_config_data
  task_config_data=$(kubectl --context "$CTX_DOGFOOD" get configmap adapter1-hyperfleet-adapter-task \
    -n "$ns_broken" -o jsonpath='{.data.task-config\.yaml}' 2>/dev/null) || task_config_data=""

  if echo "$task_config_data" | grep -q "clusters-BROKEN" 2>/dev/null; then
    pass "[$tag] Broken precondition URL (/clusters-BROKEN/) active in task config"
  else
    fail "[$tag] Broken precondition URL not found in task config"
  fi

  # ── Pre-seeded stuck clusters ──

  section "$tag: Pre-seeded Stuck Clusters"

  local total_broken
  total_broken=$(curl -s --max-time 5 "${api_url}/api/hyperfleet/v1/clusters" 2>/dev/null \
    | jq '.total // 0') || total_broken=0

  if [[ "$total_broken" -ge 2 ]]; then
    pass "[$tag] Pre-seeded clusters exist ($total_broken found)"
  else
    fail "[$tag] Expected >= 2 pre-seeded clusters, found $total_broken"
  fi

  local stuck_count
  stuck_count=$(curl -s --max-time 5 "${api_url}/api/hyperfleet/v1/clusters" 2>/dev/null \
    | jq '[.items[]? | select(.status.conditions[]? | select(.type=="Reconciled" and .status=="False"))] | length') || stuck_count=0

  if [[ "$stuck_count" -ge 2 ]]; then
    pass "[$tag] $stuck_count clusters stuck at Reconciled=False"
  else
    fail "[$tag] Only $stuck_count clusters stuck (expected >= 2)"
  fi

  # ── New cluster stays stuck ──

  section "$tag: New Cluster Stays Stuck"

  cleanup_stale "$api_url" "scenario3-"

  local broken_id
  broken_id=$(create_cluster "$api_url" "scenario3-test-${DATE_SUFFIX}") || true

  if [[ -n "$broken_id" ]]; then
    pass "[$tag] Test cluster created on broken API (id=${broken_id:0:12}...)"
  else
    fail "[$tag] Failed to create test cluster on broken API"
    return
  fi

  echo "  Waiting 30s to confirm cluster stays stuck..."
  sleep 30

  local broken_reconciled
  broken_reconciled=$(curl -s --max-time 5 \
    "${api_url}/api/hyperfleet/v1/clusters/${broken_id}" 2>/dev/null \
    | jq -r '.status.conditions[]? | select(.type=="Reconciled") | .status // "unknown"') || broken_reconciled="unknown"

  if [[ "$broken_reconciled" == "False" ]]; then
    pass "[$tag] Test cluster stays Reconciled=False after 30s (stuck as expected)"
  else
    fail "[$tag] Test cluster is Reconciled=$broken_reconciled (expected False, should be stuck)"
  fi

  # ── Status observability ──

  section "$tag: Status Observability"

  local broken_statuses
  broken_statuses=$(curl -s --max-time 5 \
    "${api_url}/api/hyperfleet/v1/clusters/${broken_id}/statuses" 2>/dev/null)

  local broken_status_count
  broken_status_count=$(echo "$broken_statuses" | jq '.total // 0') || broken_status_count=0

  local adapter1_reported
  adapter1_reported=$(echo "$broken_statuses" \
    | jq '[.items[]? | select(.adapter=="adapter1")] | length') || adapter1_reported=0

  if [[ "$adapter1_reported" -eq 0 ]]; then
    pass "[$tag] Adapter1 has not reported status (broken precondition prevents reporting)"
  else
    local adapter1_health
    adapter1_health=$(echo "$broken_statuses" \
      | jq -r '.items[]? | select(.adapter=="adapter1") | .conditions[]? | select(.type=="Health") | .status // "unknown"') || adapter1_health="unknown"
    if [[ "$adapter1_health" == "False" || "$adapter1_health" == "Unknown" ]]; then
      pass "[$tag] Adapter1 reports Health=$adapter1_health (broken as expected)"
    else
      fail "[$tag] Adapter1 reports Health=$adapter1_health (expected False, Unknown, or no report)"
    fi
  fi

  local adapter2_available
  adapter2_available=$(echo "$broken_statuses" \
    | jq -r '.items[]? | select(.adapter=="adapter2") | .conditions[]? | select(.type=="Available") | .status // "missing"') || adapter2_available="missing"

  if [[ "$adapter2_available" == "True" ]]; then
    pass "[$tag] Adapter2 still reports Available=True (not broken)"
  elif [[ "$adapter2_available" == "missing" ]]; then
    warn "[$tag] Adapter2 status not yet reported (may need more time)"
  else
    warn "[$tag] Adapter2 reports Available=$adapter2_available"
  fi

  if [[ "$CLEANUP" == true ]]; then
    cleanup_cluster "$api_url" "$broken_id"
    echo "  Test cluster cleaned up (pre-seeded stuck clusters preserved)"
  fi
}

test_scenario_3() {
  if [[ "$REGION_FILTER" == "all" || "$REGION_FILTER" == "americas" ]]; then
    _test_scenario_3_region "$NS_BROKEN_AMERICAS" "americas"
  fi
  if [[ "$REGION_FILTER" == "all" || "$REGION_FILTER" == "europe" ]]; then
    _test_scenario_3_region "$NS_BROKEN_EUROPE" "europe"
  fi
}

# ── Scenario 4: Build Your Own Adapter ──

test_scenario_4() {
  local ctx="$CTX_BUILD"

  # Determine participant namespace
  local participant_ns
  if [[ -n "$PARTICIPANT_NS_OVERRIDE" ]]; then
    participant_ns="$PARTICIPANT_NS_OVERRIDE"
  else
    local gcloud_user
    gcloud_user=$(gcloud config get-value account 2>/dev/null | cut -d@ -f1) || gcloud_user=""
    if [[ -z "$gcloud_user" ]]; then
      fail "[S4] Could not detect gcloud user. Use --namespace to specify participant namespace"
      return
    fi
    participant_ns="hackathon-${gcloud_user}"
  fi

  local api_url
  api_url=$(get_api_url "$ctx" "$NS_HYPERFLEET") || {
    fail "[S4] Could not get API LoadBalancer IP for $NS_HYPERFLEET"
    return
  }

  section "Scenario 4: Build Your Own Adapter"
  echo "  API: $api_url"
  echo "  Participant namespace: $participant_ns"

  # ── Infrastructure checks ──

  section "S4: Infrastructure"

  # Verify participant namespace exists
  if kubectl --context "$ctx" get namespace "$participant_ns" &>/dev/null; then
    pass "[S4] Participant namespace $participant_ns exists"
  else
    fail "[S4] Participant namespace $participant_ns not found. Run: make create-hackathon-namespaces"
    return
  fi

  # API accessible
  local api_status
  api_status=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 \
    "${api_url}/api/hyperfleet/v1/clusters" 2>/dev/null) || api_status="error"

  if [[ "$api_status" == "200" ]]; then
    pass "[S4] API responds (HTTP 200)"
  else
    fail "[S4] API not responding (HTTP $api_status)"
    return
  fi

  # RabbitMQ running
  local rabbitmq_ready
  rabbitmq_ready=$(kubectl --context "$ctx" get deploy rabbitmq \
    -n "$NS_HYPERFLEET" -o jsonpath='{.status.readyReplicas}' 2>/dev/null) || rabbitmq_ready=0

  if [[ "$rabbitmq_ready" -ge 1 ]]; then
    pass "[S4] RabbitMQ running"
  else
    fail "[S4] RabbitMQ not ready"
  fi

  # Sentinels running
  local sentinel_ready
  sentinel_ready=$(kubectl --context "$ctx" get deploy clusters-hyperfleet-sentinel \
    -n "$NS_HYPERFLEET" -o jsonpath='{.status.readyReplicas}' 2>/dev/null) || sentinel_ready=0

  if [[ "$sentinel_ready" -ge 1 ]]; then
    pass "[S4] Sentinel running"
  else
    fail "[S4] Sentinel not ready"
  fi

  # No pre-deployed adapters
  local adapter_count
  adapter_count=$(kubectl --context "$ctx" get deploy -n "$NS_HYPERFLEET" --no-headers 2>/dev/null \
    | grep -c "adapter" || true)

  if [[ "$adapter_count" == "0" ]]; then
    pass "[S4] No pre-deployed adapters (correct for Scenario 4)"
  else
    warn "[S4] Found $adapter_count adapter deployment(s) in $NS_HYPERFLEET"
  fi

  # ── Deploy test adapter ──

  section "S4: Deploy Test Adapter"

  # Verify test adapter configs exist
  if [[ ! -f "${TEST_ADAPTER_CONFIGS}/adapter-config.yaml" || ! -f "${TEST_ADAPTER_CONFIGS}/adapter-task-config.yaml" ]]; then
    fail "[S4] Test adapter configs not found at ${TEST_ADAPTER_CONFIGS}"
    return
  fi

  # Clean up any stale test adapter from previous runs
  helm --kube-context "$ctx" uninstall scenario4-test -n "$participant_ns" 2>/dev/null || true

  # Deploy test adapter via helm
  local helm_result
  helm_result=$(helm --kube-context "$ctx" upgrade --install scenario4-test \
    hyperfleet-adapter/hyperfleet-adapter \
    --namespace "$participant_ns" \
    --set image.registry=quay.io \
    --set image.repository=redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-adapter \
    --set image.tag=latest \
    --set image.pullPolicy=Always \
    --set broker.type=rabbitmq \
    --set broker.rabbitmq.url="amqp://guest:guest@rabbitmq.${NS_HYPERFLEET}:5672" \
    --set broker.rabbitmq.queue="${NS_HYPERFLEET}-clusters-scenario4-test" \
    --set broker.rabbitmq.exchange="${NS_HYPERFLEET}-clusters" \
    --set 'broker.rabbitmq.routingKey=#' \
    --set-file adapterConfig.yaml="${TEST_ADAPTER_CONFIGS}/adapter-config.yaml" \
    --set-file adapterTaskConfig.yaml="${TEST_ADAPTER_CONFIGS}/adapter-task-config.yaml" \
    --set 'env[0].name=NAMESPACE' \
    --set 'env[0].valueFrom.fieldRef.fieldPath=metadata.namespace' \
    --set "adapterConfig.hyperfleetApi.baseUrl=http://hyperfleet-api.${NS_HYPERFLEET}:8000" \
    --set 'rbac.resources[0]=configmaps' \
    --wait --timeout 2m 2>&1) || true

  # Check if adapter pod is running
  local pod_status
  pod_status=$(kubectl --context "$ctx" get pods -n "$participant_ns" \
    -l app.kubernetes.io/instance=scenario4-test --no-headers 2>/dev/null \
    | awk '{print $3}' | head -1) || pod_status=""

  if [[ "$pod_status" == "Running" ]]; then
    pass "[S4] Test adapter pod is Running in $participant_ns"
  else
    fail "[S4] Test adapter pod is not Running (status: ${pod_status:-not found})"
    echo "  Helm output: $(echo "$helm_result" | tail -3)"
    # Try to show pod events for debugging
    kubectl --context "$ctx" get events -n "$participant_ns" --sort-by='.lastTimestamp' 2>/dev/null | tail -5
    if [[ "$CLEANUP" == true ]]; then
      helm --kube-context "$ctx" uninstall scenario4-test -n "$participant_ns" 2>/dev/null || true
    fi
    return
  fi

  # Verify no restarts after a brief wait (indicates stable connection to broker)
  sleep 10
  local restarts
  restarts=$(kubectl --context "$ctx" get pods -n "$participant_ns" \
    -l app.kubernetes.io/instance=scenario4-test -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null) || restarts="unknown"

  if [[ "$restarts" == "0" ]]; then
    pass "[S4] Test adapter stable (0 restarts after 10s)"
  else
    warn "[S4] Test adapter has $restarts restart(s) after 10s"
  fi

  # ── Test reconciliation loop ──

  section "S4: Adapter in Reconciliation Loop"

  # Clean up stale test clusters
  cleanup_stale "$api_url" "scenario4-"

  # Create a cluster
  local cluster_id
  cluster_id=$(create_cluster "$api_url" "scenario4-test-${DATE_SUFFIX}") || true

  if [[ -n "$cluster_id" ]]; then
    pass "[S4] Test cluster created (id=${cluster_id:0:12}...)"
  else
    fail "[S4] Failed to create test cluster"
    if [[ "$CLEANUP" == true ]]; then
      helm --kube-context "$ctx" uninstall scenario4-test -n "$participant_ns" 2>/dev/null || true
    fi
    return
  fi

  # Wait for the test adapter to process the cluster and report status
  # Since scenario4-test is NOT in the API's required adapters list, the cluster
  # may reconcile without it. We check for the adapter's status report instead.
  echo "  Waiting for test adapter to report status (up to ${RECONCILE_TIMEOUT}s)..."

  local elapsed=0
  local adapter_reported=false

  while [[ $elapsed -lt $RECONCILE_TIMEOUT ]]; do
    local status_response
    status_response=$(curl -s --max-time 5 \
      "${api_url}/api/hyperfleet/v1/clusters/${cluster_id}/statuses" 2>/dev/null)

    local found_adapter
    found_adapter=$(echo "$status_response" \
      | jq '[.items[]? | select(.adapter=="scenario4-test")] | length') || found_adapter=0

    if [[ "$found_adapter" -ge 1 ]]; then
      adapter_reported=true
      break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  if [[ "$adapter_reported" == true ]]; then
    pass "[S4] Test adapter reported status in ${elapsed}s"
  else
    fail "[S4] Test adapter did NOT report status after ${RECONCILE_TIMEOUT}s"
    # Show adapter logs for debugging
    echo "  Last 10 adapter log lines:"
    kubectl --context "$ctx" logs -l app.kubernetes.io/instance=scenario4-test \
      -n "$participant_ns" --tail=10 2>/dev/null | head -10
    if [[ "$CLEANUP" == true ]]; then
      cleanup_cluster "$api_url" "$cluster_id"
      helm --kube-context "$ctx" uninstall scenario4-test -n "$participant_ns" 2>/dev/null || true
    fi
    return
  fi

  # Verify adapter status conditions
  local adapter_status
  adapter_status=$(curl -s --max-time 5 \
    "${api_url}/api/hyperfleet/v1/clusters/${cluster_id}/statuses" 2>/dev/null)

  local applied
  applied=$(echo "$adapter_status" \
    | jq -r '.items[]? | select(.adapter=="scenario4-test") | .conditions[]? | select(.type=="Applied") | .status // "missing"') || applied="missing"

  if [[ "$applied" == "True" ]]; then
    pass "[S4] Test adapter reports Applied=True"
  else
    fail "[S4] Test adapter reports Applied=$applied (expected True)"
  fi

  # Verify ConfigMap was created in participant namespace
  local configmap_name="${cluster_id}-scenario4-test"
  if kubectl --context "$ctx" get configmap "$configmap_name" -n "$participant_ns" &>/dev/null; then
    pass "[S4] ConfigMap created in $participant_ns ($configmap_name)"
  else
    fail "[S4] ConfigMap not found in $participant_ns (expected $configmap_name)"
  fi

  # ── Cleanup ──

  if [[ "$CLEANUP" == true ]]; then
    section "S4: Cleanup"
    cleanup_cluster "$api_url" "$cluster_id"
    helm --kube-context "$ctx" uninstall scenario4-test -n "$participant_ns" 2>/dev/null || true
    # Wait for configmap cleanup
    sleep 5
    kubectl --context "$ctx" delete configmap -l app.kubernetes.io/instance=scenario4-test \
      -n "$participant_ns" 2>/dev/null || true
    echo "  Test adapter and cluster cleaned up"
  fi
}

# ── Scenario 5: Shard the Sentinel ──

test_scenario_5() {
  local ctx="$CTX_OPERATE"

  # Determine participant namespace (same logic as S4)
  local participant_ns
  if [[ -n "$PARTICIPANT_NS_OVERRIDE" ]]; then
    participant_ns="$PARTICIPANT_NS_OVERRIDE"
  else
    local gcloud_user
    gcloud_user=$(gcloud config get-value account 2>/dev/null | cut -d@ -f1) || gcloud_user=""
    if [[ -z "$gcloud_user" ]]; then
      fail "[S5] Could not detect gcloud user. Use --namespace to specify participant namespace"
      return
    fi
    participant_ns="hackathon-${gcloud_user}"
  fi

  local api_url
  api_url=$(get_api_url "$ctx" "$NS_HYPERFLEET") || {
    fail "[S5] Could not get API LoadBalancer IP for $NS_HYPERFLEET"
    return
  }

  section "Scenario 5: Shard the Sentinel"
  echo "  API: $api_url"
  echo "  Participant namespace: $participant_ns"

  # ── Infrastructure checks ──

  section "S5: Infrastructure"

  # Participant namespace exists
  if kubectl --context "$ctx" get namespace "$participant_ns" &>/dev/null; then
    pass "[S5] Participant namespace $participant_ns exists"
  else
    fail "[S5] Participant namespace $participant_ns not found"
    return
  fi

  # API accessible
  local api_status
  api_status=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 \
    "${api_url}/api/hyperfleet/v1/clusters" 2>/dev/null) || api_status="error"

  if [[ "$api_status" == "200" ]]; then
    pass "[S5] API responds (HTTP 200)"
  else
    fail "[S5] API not responding (HTTP $api_status)"
    return
  fi

  # Catch-all sentinel running
  local sentinel_ready
  sentinel_ready=$(kubectl --context "$ctx" get deploy clusters-hyperfleet-sentinel \
    -n "$NS_HYPERFLEET" -o jsonpath='{.status.readyReplicas}' 2>/dev/null) || sentinel_ready=0

  if [[ "$sentinel_ready" -ge 1 ]]; then
    pass "[S5] Catch-all sentinel running"
  else
    fail "[S5] Catch-all sentinel not ready"
  fi

  # Seeded clusters exist
  local seeded_count
  seeded_count=$(curl -s --max-time 10 "${api_url}/api/hyperfleet/v1/clusters?size=50" 2>/dev/null \
    | jq '.total // 0') || seeded_count=0

  if [[ "$seeded_count" -ge 12 ]]; then
    pass "[S5] $seeded_count seeded clusters found (expected >= 12)"
  else
    fail "[S5] Only $seeded_count seeded clusters (expected >= 12)"
  fi

  # Region distribution
  local us_east us_west eu_west
  us_east=$(curl -s --max-time 10 "${api_url}/api/hyperfleet/v1/clusters?size=50" 2>/dev/null \
    | jq '[.items[]? | select(.labels.region == "us-east")] | length') || us_east=0
  us_west=$(curl -s --max-time 10 "${api_url}/api/hyperfleet/v1/clusters?size=50" 2>/dev/null \
    | jq '[.items[]? | select(.labels.region == "us-west")] | length') || us_west=0
  eu_west=$(curl -s --max-time 10 "${api_url}/api/hyperfleet/v1/clusters?size=50" 2>/dev/null \
    | jq '[.items[]? | select(.labels.region == "eu-west")] | length') || eu_west=0

  if [[ "$us_east" -ge 4 && "$us_west" -ge 4 && "$eu_west" -ge 4 ]]; then
    pass "[S5] Region distribution correct: us-east=$us_east, us-west=$us_west, eu-west=$eu_west"
  else
    fail "[S5] Region distribution wrong: us-east=$us_east, us-west=$us_west, eu-west=$eu_west (expected >= 4/4/4)"
  fi

  # ── Deploy regional sentinel ──

  section "S5: Deploy Regional Sentinel (us-east)"

  # Clean up any stale test sentinel from previous runs
  helm --kube-context "$ctx" uninstall sentinel-us-east -n "$participant_ns" 2>/dev/null || true

  # Deploy a us-east regional sentinel
  local helm_result
  helm_result=$(helm --kube-context "$ctx" upgrade --install sentinel-us-east \
    hyperfleet-sentinel/hyperfleet-sentinel \
    --namespace "$participant_ns" \
    --set image.registry=quay.io \
    --set image.repository=redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-sentinel \
    --set image.tag=latest \
    --set image.pullPolicy=Always \
    --set config.resourceType=clusters \
    --set config.resourceSelector[0].label=region \
    --set config.resourceSelector[0].value=us-east \
    --set "config.clients.hyperfleetApi.baseUrl=http://hyperfleet-api.${NS_HYPERFLEET}:8000" \
    --set broker.type=rabbitmq \
    --set "broker.topic=${NS_HYPERFLEET}-clusters" \
    --set "broker.rabbitmq.url=amqp://guest:guest@rabbitmq.${NS_HYPERFLEET}:5672" \
    --set broker.rabbitmq.exchangeType=topic \
    --wait --timeout 2m 2>&1) || true

  # Check if sentinel pod is running
  local pod_status
  pod_status=$(kubectl --context "$ctx" get pods -n "$participant_ns" \
    -l app.kubernetes.io/instance=sentinel-us-east --no-headers 2>/dev/null \
    | awk '{print $3}' | head -1) || pod_status=""

  if [[ "$pod_status" == "Running" ]]; then
    pass "[S5] Regional sentinel (us-east) running in $participant_ns"
  else
    fail "[S5] Regional sentinel not running (status: ${pod_status:-not found})"
    echo "  Helm output: $(echo "$helm_result" | tail -3)"
    if [[ "$CLEANUP" == true ]]; then
      helm --kube-context "$ctx" uninstall sentinel-us-east -n "$participant_ns" 2>/dev/null || true
    fi
    return
  fi

  # Verify stability
  sleep 10
  local restarts
  restarts=$(kubectl --context "$ctx" get pods -n "$participant_ns" \
    -l app.kubernetes.io/instance=sentinel-us-east -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null) || restarts="unknown"

  if [[ "$restarts" == "0" ]]; then
    pass "[S5] Regional sentinel stable (0 restarts after 10s)"
  else
    warn "[S5] Regional sentinel has $restarts restart(s) after 10s"
  fi

  # ── Scale down catch-all and test regional sentinel ──

  section "S5: Sentinel Sharding Test"

  # Scale down the catch-all sentinel
  kubectl --context "$ctx" scale deploy clusters-hyperfleet-sentinel \
    -n "$NS_HYPERFLEET" --replicas=0 2>/dev/null
  echo "  Catch-all sentinel scaled down"

  # Wait for the regional sentinel to pick up events
  sleep 10

  # Clean up stale test clusters
  cleanup_stale "$api_url" "scenario5-"

  # Create a us-east cluster -- should be picked up by the regional sentinel
  local cluster_id
  cluster_id=$(curl -sS -w "" -X POST \
    -H "Content-Type: application/json" ${API_IDENTITY_HEADER} \
    "${api_url}/api/hyperfleet/v1/clusters" \
    -d "{\"name\":\"scenario5-test-${DATE_SUFFIX}\",\"kind\":\"Cluster\",\"spec\":{\"provider\":\"gcp\",\"region\":\"us-east1\"},\"labels\":{\"region\":\"us-east\",\"environment\":\"hackathon\"}}" \
    --connect-timeout 5 --max-time 15 2>/dev/null \
    | jq -r '.id // empty') || cluster_id=""

  if [[ -n "$cluster_id" ]]; then
    pass "[S5] Test cluster created with region=us-east (id=${cluster_id:0:12}...)"
  else
    fail "[S5] Failed to create test cluster"
    # Restore catch-all before returning
    kubectl --context "$ctx" scale deploy clusters-hyperfleet-sentinel \
      -n "$NS_HYPERFLEET" --replicas=1 2>/dev/null
    if [[ "$CLEANUP" == true ]]; then
      helm --kube-context "$ctx" uninstall sentinel-us-east -n "$participant_ns" 2>/dev/null || true
    fi
    return
  fi

  # Wait for reconciliation (via the regional sentinel + existing adapters)
  local elapsed
  if elapsed=$(wait_reconciled "$api_url" "$cluster_id"); then
    pass "[S5] Cluster reconciled via regional sentinel in ${elapsed}s"
  else
    fail "[S5] Cluster NOT reconciled after ${RECONCILE_TIMEOUT}s (regional sentinel may not be publishing events)"
  fi

  # Verify adapter statuses are reported (proves the sentinel published events that adapters consumed)
  local status_count
  status_count=$(curl -s --max-time 5 \
    "${api_url}/api/hyperfleet/v1/clusters/${cluster_id}/statuses" 2>/dev/null \
    | jq '.total // 0') || status_count=0

  if [[ "$status_count" -ge 1 ]]; then
    pass "[S5] $status_count adapter(s) reported status via regional sentinel"
  else
    fail "[S5] No adapter statuses reported (regional sentinel may not be publishing to correct topic)"
  fi

  # ── Restore and cleanup ──

  section "S5: Restore & Cleanup"

  # Scale catch-all sentinel back up
  kubectl --context "$ctx" scale deploy clusters-hyperfleet-sentinel \
    -n "$NS_HYPERFLEET" --replicas=1 2>/dev/null
  echo "  Catch-all sentinel restored"

  if [[ "$CLEANUP" == true ]]; then
    cleanup_cluster "$api_url" "$cluster_id"
    helm --kube-context "$ctx" uninstall sentinel-us-east -n "$participant_ns" 2>/dev/null || true
    echo "  Regional sentinel and test cluster cleaned up"
  fi
}

# ── Main ──

echo "════════════════════════════════════════════"
echo "  HACKATHON SCENARIO TESTS"
echo "════════════════════════════════════════════"
echo "  Timeout: ${RECONCILE_TIMEOUT}s"
echo "  Cleanup: ${CLEANUP}"
echo "  Scenarios: ${SCENARIO_FILTER}"
echo "  Region: ${REGION_FILTER}"

check_prereqs

case "$SCENARIO_FILTER" in
  1)   test_scenario_1 ;;
  2)   test_scenario_2 ;;
  3)   test_scenario_3 ;;
  4)   test_scenario_4 ;;
  5)   test_scenario_5 ;;
  all)
    test_scenario_1
    test_scenario_2
    test_scenario_3
    test_scenario_4
    test_scenario_5
    ;;
  *)
    echo "ERROR: invalid scenario: $SCENARIO_FILTER (valid: 1, 2, 3, 4, 5, all)"
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
