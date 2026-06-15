#!/usr/bin/env bash
# Seeds the HyperFleet API with clusters for the hackathon.
#
# Usage: ./scripts/seed-hackathon-clusters.sh [API_URL] [--broken-americas URL] [--broken-europe URL]
#
# Default API_URL: http://localhost:8000 (use kubectl port-forward first)
#
# Creates:
#   - 12 region-labeled clusters for Scenario 5 (Sentinel sharding)
#   - 2 clusters on each broken API for Scenario 3 (per-region isolation)

set -euo pipefail

API_URL="${1:-http://localhost:8000}"
API_BASE="${API_URL}/api/hyperfleet/v1"
BROKEN_AMERICAS_API_URL=""
BROKEN_EUROPE_API_URL=""

# Parse flags
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --broken-americas)
      BROKEN_AMERICAS_API_URL="$2"
      shift 2
      ;;
    --broken-europe)
      BROKEN_EUROPE_API_URL="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

create_cluster() {
  local api_base="$1" name="$2" kind="$3" labels="$4"

  echo -n "  Creating ${name}... "

  local status
  status=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    -H "Content-Type: application/json" \
    -H "X-HyperFleet-Identity: hackathon-facilitator@redhat.com" \
    "${api_base}/clusters" \
    -d "{
      \"name\": \"${name}\",
      \"kind\": \"${kind}\",
      \"labels\": ${labels},
      \"spec\": {\"provider\": \"gcp\", \"region\": \"us-east1\"}
    }" 2>/dev/null) || status="error"

  case "$status" in
    201) echo "created"; return 0 ;;
    409) echo "already exists"; return 0 ;;
    *)   echo "FAILED (HTTP ${status})"; return 1 ;;
  esac
}

# ── Scenario 5: Region-labeled clusters for Sentinel sharding ──

echo "Seeding hackathon clusters via ${API_BASE}..."
echo ""

REGIONS=("us-east" "us-west" "eu-west")
CLUSTERS_PER_REGION=4
CREATED=0

for region in "${REGIONS[@]}"; do
  for i in $(seq 1 ${CLUSTERS_PER_REGION}); do
    name="hackathon-${region}-${i}"
    labels="{\"region\": \"${region}\", \"environment\": \"hackathon\", \"scenario\": \"sentinel-sharding\"}"

    if create_cluster "$API_BASE" "$name" "Cluster" "$labels"; then
      CREATED=$((CREATED + 1))
    fi
  done
done

echo ""
echo "Done. ${CREATED} regional clusters seeded."

# ── Scenario 3: Stuck clusters on the broken APIs (per-region) ──

seed_broken_region() {
  local region="$1" api_url="$2"
  local broken_base="${api_url}/api/hyperfleet/v1"
  echo ""
  echo "Seeding broken clusters for ${region} via ${broken_base}..."
  echo ""

  local broken_created=0
  local broken_clusters=("stuck-cluster-alpha" "stuck-cluster-beta")

  for name in "${broken_clusters[@]}"; do
    local labels="{\"environment\": \"hackathon\", \"scenario\": \"debugging\", \"purpose\": \"stuck-cluster\", \"region\": \"${region}\"}"

    if create_cluster "$broken_base" "$name" "Cluster" "$labels"; then
      broken_created=$((broken_created + 1))
    fi
  done

  echo ""
  echo "Done. ${broken_created} broken clusters seeded for ${region}."
}

if [[ -n "$BROKEN_AMERICAS_API_URL" ]]; then
  seed_broken_region "americas" "$BROKEN_AMERICAS_API_URL"
fi

if [[ -n "$BROKEN_EUROPE_API_URL" ]]; then
  seed_broken_region "europe" "$BROKEN_EUROPE_API_URL"
fi

echo ""
echo "Verify with:"
echo "  curl ${API_BASE}/clusters | jq '.total'"
if [[ -n "$BROKEN_AMERICAS_API_URL" ]]; then
  echo "  curl ${BROKEN_AMERICAS_API_URL}/api/hyperfleet/v1/clusters | jq '.total'"
fi
if [[ -n "$BROKEN_EUROPE_API_URL" ]]; then
  echo "  curl ${BROKEN_EUROPE_API_URL}/api/hyperfleet/v1/clusters | jq '.total'"
fi
