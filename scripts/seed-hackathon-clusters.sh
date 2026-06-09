#!/usr/bin/env bash
# Seeds the HyperFleet API with region-labeled clusters for Scenario 5 (Sentinel sharding).
#
# Usage: ./scripts/seed-hackathon-clusters.sh [API_URL]
#
# Default API_URL: http://localhost:8000 (use kubectl port-forward first)
#
# Creates 12 clusters across 3 regions:
#   4x region=us-east
#   4x region=us-west
#   4x region=eu-west

set -euo pipefail

API_URL="${1:-http://localhost:8000}"
API_BASE="${API_URL}/api/hyperfleet/v1"

echo "Seeding hackathon clusters via ${API_BASE}..."
echo ""

REGIONS=("us-east" "us-west" "eu-west")
CLUSTERS_PER_REGION=4
CREATED=0

for region in "${REGIONS[@]}"; do
  for i in $(seq 1 ${CLUSTERS_PER_REGION}); do
    name="hackathon-${region}-${i}"

    echo -n "  Creating ${name} (region=${region})... "

    status=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
      -H "Content-Type: application/json" \
      "${API_BASE}/clusters" \
      -d "{
        \"name\": \"${name}\",
        \"labels\": {
          \"region\": \"${region}\",
          \"environment\": \"hackathon\",
          \"scenario\": \"sentinel-sharding\"
        }
      }" 2>/dev/null) || status="error"

    case "$status" in
      201) echo "created"; CREATED=$((CREATED + 1)) ;;
      409) echo "already exists" ;;
      *)   echo "FAILED (HTTP ${status})" ;;
    esac
  done
done

echo ""
echo "Done. ${CREATED} clusters created."
echo ""
echo "Verify with:"
echo "  curl ${API_BASE}/clusters?labels=environment%3Dhackathon | jq '.items | length'"
