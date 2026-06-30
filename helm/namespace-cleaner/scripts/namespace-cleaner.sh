#!/bin/bash
set -eo pipefail

LABEL_SELECTOR="${LABEL_SELECTOR:-hyperfleet.io/cluster-id hyperfleet.io/test-run}"
AGE_MINUTES="${AGE_MINUTES:-180}"
MAESTRO_URL="${MAESTRO_URL:-http://maestro.maestro.svc.cluster.local:8000}"
DRY_RUN="${DRY_RUN:-false}"

if [ -z "${LABEL_SELECTOR}" ]; then
  echo "[ERROR] LABEL_SELECTOR must not be empty" >&2; exit 1
fi
if ! echo "${AGE_MINUTES}" | grep -qE '^[1-9][0-9]*$'; then
  echo "[ERROR] AGE_MINUTES must be a positive integer, got: '${AGE_MINUTES}'" >&2; exit 1
fi
if [ "${DRY_RUN}" != "true" ] && [ "${DRY_RUN}" != "false" ]; then
  echo "[ERROR] DRY_RUN must be 'true' or 'false', got: '${DRY_RUN}'" >&2; exit 1
fi

NOW=$(date +%s)
AGE_SECONDS=$((AGE_MINUTES * 60))

# Parse an ISO 8601 timestamp to epoch seconds.
# Strips sub-second precision before parsing, then tries:
#   1. GNU date   (Linux, Debian-based images)
#   2. busybox date with -D format flag (Alpine)
#   3. BSD date   (macOS)
parse_timestamp() {
  local ts="${1%%.*}"   # strip sub-second precision
  ts="${ts%Z}Z"         # ensure exactly one trailing Z (handles timestamps with or without fractional seconds)
  date -d "${ts}" +%s 2>/dev/null \
    || date -D "%Y-%m-%dT%H:%M:%SZ" -d "${ts}" +%s 2>/dev/null \
    || TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "${ts}" +%s
}

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [INFO] Starting namespace cleaner (label_selector=${LABEL_SELECTOR}, age_minutes=${AGE_MINUTES}, maestro_url=${MAESTRO_URL}, dry_run=${DRY_RUN})"

# --- Step 1: delete stale Maestro resource bundles ---
if curl -sf --connect-timeout 5 --max-time 10 "${MAESTRO_URL}/api/maestro/v1/consumers" > /dev/null 2>&1; then
  BUNDLES_JSON=$(curl -sS --max-time 30 "${MAESTRO_URL}/api/maestro/v1/resource-bundles?size=500" || true)
  total=$(echo "${BUNDLES_JSON}" | jq '.total' 2>/dev/null || true)
  if ! printf '%s' "${total}" | grep -qE '^[0-9]+$'; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [WARN] Could not parse Maestro bundle response, skipping bundle cleanup"
  else
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [INFO] Fetched ${total} Maestro resource bundles"
    if [ "${total}" -gt 500 ]; then
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [WARN] More than 500 bundles exist; only the first 500 will be considered"
    fi

    echo "${BUNDLES_JSON}" | jq -r '.items[] | "\(.id) \(.created_at)"' \
    | while read -r bundle_id created_at; do
        created_seconds=$(parse_timestamp "${created_at}") || continue
        age=$((NOW - created_seconds))
        if [ "${age}" -gt "${AGE_SECONDS}" ]; then
          age_m=$((age / 60))
          if [ "${DRY_RUN}" = "true" ]; then
            echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [DRY-RUN] Would delete Maestro bundle '${bundle_id}' (age=${age_m}m)"
          else
            echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [INFO] Deleting Maestro bundle '${bundle_id}' (age=${age_m}m)"
            http_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 -X DELETE \
              "${MAESTRO_URL}/api/maestro/v1/resource-bundles/${bundle_id}")
            if [ "${http_code}" = "204" ]; then
              echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [INFO] Maestro bundle '${bundle_id}' deleted"
            else
              echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [WARN] Maestro bundle delete returned HTTP ${http_code} for '${bundle_id}'"
            fi
          fi
        fi
      done || true
  fi
else
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [WARN] Maestro API not reachable at ${MAESTRO_URL}, skipping bundle cleanup"
fi

# --- Step 2: delete stale namespaces (non-blocking) ---
# LABEL_SELECTOR may contain multiple space-separated selectors; each is matched
# independently (OR semantics). Namespaces already Terminating are skipped.
IFS=' ' read -ra _selectors <<< "${LABEL_SELECTOR}"
for selector in "${_selectors[@]}"; do
  kubectl get namespaces -l "${selector}" \
    -o go-template='{{range .items}}{{.metadata.name}}|{{.metadata.creationTimestamp}}|{{.status.phase}}{{"\n"}}{{end}}' \
  | while IFS='|' read -r ns_name created_at phase; do
      [ -z "${ns_name}" ] && continue
      [ "${phase}" != "Active" ] && continue

      created_seconds=$(parse_timestamp "${created_at}") || continue
      age=$((NOW - created_seconds))

      if [ "${age}" -gt "${AGE_SECONDS}" ]; then
        age_m=$((age / 60))
        if [ "${DRY_RUN}" = "true" ]; then
          echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [DRY-RUN] Would delete namespace '${ns_name}' (age=${age_m}m)"
        else
          echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [INFO] Deleting namespace '${ns_name}' (age=${age_m}m)"
          kubectl delete namespace "${ns_name}" --wait=false \
            && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [INFO] Delete requested for namespace '${ns_name}'" \
            || echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [WARN] Failed to delete namespace '${ns_name}'"
        fi
      fi
    done
done

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [INFO] Namespace cleaner run complete"
