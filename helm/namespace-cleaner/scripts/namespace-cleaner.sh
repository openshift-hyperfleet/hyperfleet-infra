#!/bin/bash
set -eo pipefail

LABEL_SELECTOR="${LABEL_SELECTOR:-hyperfleet.io/cluster-id hyperfleet.io/test-run}"
AGE_MINUTES="${AGE_MINUTES:-120}"
DRY_RUN="${DRY_RUN:-false}"
ORPHANS_ENABLED="${ORPHANS_ENABLED:-false}"
PUBSUB_PROJECT="${PUBSUB_PROJECT:-}"
OWNER_CLUSTER="${OWNER_CLUSTER:-}"

if [ -z "${LABEL_SELECTOR}" ]; then
  echo "[ERROR] LABEL_SELECTOR must not be empty" >&2; exit 1
fi
if ! echo "${AGE_MINUTES}" | grep -qE '^[1-9][0-9]*$'; then
  echo "[ERROR] AGE_MINUTES must be a positive integer, got: '${AGE_MINUTES}'" >&2; exit 1
fi
if [ "${DRY_RUN}" != "true" ] && [ "${DRY_RUN}" != "false" ]; then
  echo "[ERROR] DRY_RUN must be 'true' or 'false', got: '${DRY_RUN}'" >&2; exit 1
fi
if [ "${ORPHANS_ENABLED}" != "true" ] && [ "${ORPHANS_ENABLED}" != "false" ]; then
  echo "[ERROR] ORPHANS_ENABLED must be 'true' or 'false', got: '${ORPHANS_ENABLED}'" >&2; exit 1
fi
if [ "${ORPHANS_ENABLED}" = "true" ] && ! echo "${PUBSUB_PROJECT}" | grep -qE '^[a-z][a-z0-9-]{4,28}[a-z0-9]$'; then
  echo "[ERROR] PUBSUB_PROJECT must be a GCP project ID when ORPHANS_ENABLED is true, got: '${PUBSUB_PROJECT}'" >&2; exit 1
fi
if [ "${ORPHANS_ENABLED}" = "true" ] && [ -z "${OWNER_CLUSTER}" ]; then
  echo "[ERROR] OWNER_CLUSTER must be set when ORPHANS_ENABLED is true" >&2; exit 1
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

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [INFO] Starting namespace cleaner (label_selector=${LABEL_SELECTOR}, age_minutes=${AGE_MINUTES}, dry_run=${DRY_RUN}, orphans_enabled=${ORPHANS_ENABLED})"

# --- Delete orphans of deleted E2E run namespaces (when ORPHANS_ENABLED) ---
# A Pub/Sub topic or subscription whose name starts with "<run namespace>-", and
# a Helm-managed ClusterRole or ClusterRoleBinding whose Helm release namespace
# is a run namespace, belong to that run. When the namespace no longer exists,
# the resource is deleted. Run namespaces are e2e-<19-digit Prow build ID> and
# rc-e2e-<19 digits>; the exact length keeps developer names such as e2e-123 out.
METADATA_TOKEN_URL="http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token"
METADATA_CLUSTER_NAME_URL="http://metadata.google.internal/computeMetadata/v1/instance/attributes/cluster-name"
PUBSUB_API="https://pubsub.googleapis.com/v1"
HELM_MANAGED_SELECTOR="app.kubernetes.io/managed-by=Helm"
RUN_NAMESPACE_PATTERN='^(rc-)?e2e-[0-9]{19}$'
RUN_PREFIX_PATTERN='^((rc-)?e2e-[0-9]{19})-'

ORPHANS_FOUND=0
ORPHANS_KEPT=0
ORPHANS_DELETED=0
ORPHANS_FAILED=0

log() {
  local level="$1"; shift
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [${level}] $*"
}

# Run curl and set HTTP_CODE and HTTP_BODY. HTTP_CODE is 000 when the request
# did not complete; curl's own error goes to stderr.
http_call() {
  local resp
  resp=$(curl -sS -m 30 -w '\n%{http_code}' "$@") || true
  HTTP_CODE="${resp##*$'\n'}"
  HTTP_BODY="${resp%$'\n'*}"
  if ! [[ "${HTTP_CODE}" =~ ^[0-9]{3}$ ]]; then
    HTTP_CODE=000
  fi
}

# The error status and message of a Google API error response, if any.
api_error() {
  printf '%s' "$1" | jq -r '.error | "\(.status // "") \(.message // "")"' 2>/dev/null || true
}

# Pub/Sub is shared by every cluster in the project, but each cluster sees only
# its own namespaces. On any cluster but the owner, the live runs of the owner
# would look deleted, so refuse to run unless the GKE metadata server names this
# cluster OWNER_CLUSTER. A failed lookup refuses too.
check_owner_cluster() {
  http_call -H "Metadata-Flavor: Google" "${METADATA_CLUSTER_NAME_URL}"
  if [ "${HTTP_CODE}" != "200" ]; then
    log ERROR "Failed to read the cluster name from the metadata server (HTTP ${HTTP_CODE})"
    return 1
  fi
  if [ "${HTTP_BODY}" != "${OWNER_CLUSTER}" ]; then
    log ERROR "This cluster is '${HTTP_BODY}', not the owner cluster '${OWNER_CLUSTER}'"
    return 1
  fi
}

# Set GCP_TOKEN from the GKE metadata server (Workload Identity).
gcp_token() {
  GCP_TOKEN=""
  http_call -H "Metadata-Flavor: Google" "${METADATA_TOKEN_URL}"
  if [ "${HTTP_CODE}" = "200" ]; then
    GCP_TOKEN=$(printf '%s' "${HTTP_BODY}" | jq -r '.access_token // empty') || GCP_TOKEN=""
  fi
  if [ -z "${GCP_TOKEN}" ]; then
    log ERROR "Failed to get an access token from the metadata server (HTTP ${HTTP_CODE})"
    return 1
  fi
}

# pubsub_list <topics|subscriptions>: set PUBSUB_NAMES to the full name of every
# resource of that collection in PUBSUB_PROJECT, one per line, following
# nextPageToken.
pubsub_list() {
  local collection="$1" page_token="" names
  local url="${PUBSUB_API}/projects/${PUBSUB_PROJECT}/${collection}"
  PUBSUB_NAMES=""
  while :; do
    if [ -n "${page_token}" ]; then
      http_call -G -H "Authorization: Bearer ${GCP_TOKEN}" --data-urlencode "pageToken=${page_token}" "${url}"
    else
      http_call -H "Authorization: Bearer ${GCP_TOKEN}" "${url}"
    fi
    if [ "${HTTP_CODE}" != "200" ]; then
      log ERROR "Failed to list Pub/Sub ${collection} in project '${PUBSUB_PROJECT}' (HTTP ${HTTP_CODE}): $(api_error "${HTTP_BODY}")"
      return 1
    fi
    if ! names=$(printf '%s' "${HTTP_BODY}" | jq -r --arg c "${collection}" '(.[$c] // [])[].name') \
      || ! page_token=$(printf '%s' "${HTTP_BODY}" | jq -r '.nextPageToken // empty'); then
      log ERROR "Failed to parse the Pub/Sub ${collection} list in project '${PUBSUB_PROJECT}'"
      return 1
    fi
    if [ -n "${names}" ]; then
      PUBSUB_NAMES="${PUBSUB_NAMES}${names}"$'\n'
    fi
    if [ -z "${page_token}" ]; then
      return 0
    fi
  done
}

# rbac_list <clusterroles|clusterrolebindings>: set RBAC_ITEMS to
# "<name><TAB><Helm release namespace>" for every Helm-managed object of that
# kind, one per line.
rbac_list() {
  local resource="$1" json
  if ! json=$(kubectl get "${resource}" -l "${HELM_MANAGED_SELECTOR}" -o json); then
    log ERROR "Failed to list ${resource}"
    return 1
  fi
  if ! RBAC_ITEMS=$(printf '%s' "${json}" | jq -r '.items[]
      | select(.metadata.labels["app.kubernetes.io/managed-by"] == "Helm")
      | [.metadata.name, (.metadata.annotations["meta.helm.sh/release-namespace"] // "")]
      | @tsv'); then
    log ERROR "Failed to parse the ${resource} list"
    return 1
  fi
}

# Set LIVE_NAMESPACES to every namespace name, one per line. Terminating
# namespaces are included, so their resources are kept until they are gone.
list_namespaces() {
  local json
  if ! json=$(kubectl get namespaces -o json) \
    || ! LIVE_NAMESPACES=$(printf '%s' "${json}" | jq -r '.items[].metadata.name'); then
    log ERROR "Failed to list namespaces"
    return 1
  fi
  if [ -z "${LIVE_NAMESPACES}" ]; then
    log ERROR "The namespace list is empty"
    return 1
  fi
}

namespace_exists() {
  case $'\n'"${LIVE_NAMESPACES}"$'\n' in
    *$'\n'"$1"$'\n'*) return 0 ;;
  esac
  return 1
}

# Count and log one candidate. Return 0 when it must not be deleted now (its run
# namespace exists, or DRY_RUN is true) and 1 when the caller should delete it.
skip_delete() {
  local kind="$1" name="$2" owner="$3"
  ORPHANS_FOUND=$((ORPHANS_FOUND + 1))
  if namespace_exists "${owner}"; then
    ORPHANS_KEPT=$((ORPHANS_KEPT + 1))
    log INFO "Keeping ${kind} '${name}' (namespace '${owner}' exists)"
    return 0
  fi
  if [ "${DRY_RUN}" = "true" ]; then
    log DRY-RUN "Would delete ${kind} '${name}' (namespace '${owner}' not found)"
    return 0
  fi
  return 1
}

# delete_pubsub <subscriptions|topics> <full names>
delete_pubsub() {
  local collection="$1" names="$2" kind full short owner
  kind="Pub/Sub ${collection%s}"
  while IFS= read -r full; do
    short="${full##*/}"
    [[ "${short}" =~ ${RUN_PREFIX_PATTERN} ]] || continue
    owner="${BASH_REMATCH[1]}"
    skip_delete "${kind}" "${short}" "${owner}" && continue
    http_call -X DELETE -H "Authorization: Bearer ${GCP_TOKEN}" "${PUBSUB_API}/${full}"
    case "${HTTP_CODE}" in
      2??)
        ORPHANS_DELETED=$((ORPHANS_DELETED + 1))
        log INFO "Deleted ${kind} '${short}' (namespace '${owner}' not found)" ;;
      404)
        ORPHANS_DELETED=$((ORPHANS_DELETED + 1))
        log INFO "${kind} '${short}' was already deleted (namespace '${owner}' not found)" ;;
      *)
        ORPHANS_FAILED=$((ORPHANS_FAILED + 1))
        log WARN "Failed to delete ${kind} '${short}' (HTTP ${HTTP_CODE}): $(api_error "${HTTP_BODY}")" ;;
    esac
  done <<< "${names}"
}

# delete_rbac <clusterrole|clusterrolebinding> <rbac_list items>
delete_rbac() {
  local kind="$1" items="$2" name owner
  while IFS=$'\t' read -r name owner; do
    [ -z "${name}" ] && continue
    [[ "${owner}" =~ ${RUN_NAMESPACE_PATTERN} ]] || continue
    skip_delete "${kind}" "${name}" "${owner}" && continue
    if kubectl delete "${kind}" "${name}" --ignore-not-found; then
      ORPHANS_DELETED=$((ORPHANS_DELETED + 1))
      log INFO "Deleted ${kind} '${name}' (namespace '${owner}' not found)"
    else
      ORPHANS_FAILED=$((ORPHANS_FAILED + 1))
      log WARN "Failed to delete ${kind} '${name}'"
    fi
  done <<< "${items}"
}

# List every candidate first and the namespaces last. check-hyperfleet-namespace
# creates a run's namespace before the run installs anything, so each listed
# resource already had its namespace when the namespace list is taken, and a run
# that starts during the sweep is never mistaken for a deleted one.
#
# Pub/Sub and RBAC are gated separately: each is deleted only when its own
# checks and lists succeeded, and the namespace list too. Pub/Sub needs the
# owner cluster check and a token; RBAC needs neither, so a GCP failure does not
# hold back RBAC cleanup. Returns non-zero when a kind was skipped. A failed
# delete is only logged, like a failed namespace delete.
sweep_orphans() {
  local subscriptions="" topics="" bindings="" roles="" pubsub_ok=true rbac_ok=true
  log INFO "Listing orphan candidates (pubsub_project=${PUBSUB_PROJECT}, owner_cluster=${OWNER_CLUSTER})"
  { check_owner_cluster && gcp_token \
    && pubsub_list subscriptions && subscriptions="${PUBSUB_NAMES}" \
    && pubsub_list topics && topics="${PUBSUB_NAMES}"; } || pubsub_ok=false
  { rbac_list clusterrolebindings && bindings="${RBAC_ITEMS}" \
    && rbac_list clusterroles && roles="${RBAC_ITEMS}"; } || rbac_ok=false
  if ! list_namespaces; then
    log ERROR "Orphan cleanup skipped: no orphan was deleted in this run"
    return 1
  fi

  if [ "${pubsub_ok}" = "true" ]; then
    delete_pubsub subscriptions "${subscriptions}"
    delete_pubsub topics "${topics}"
  else
    log ERROR "Pub/Sub orphan cleanup skipped: no Pub/Sub resource was deleted in this run"
  fi
  if [ "${rbac_ok}" = "true" ]; then
    delete_rbac clusterrolebinding "${bindings}"
    delete_rbac clusterrole "${roles}"
  else
    log ERROR "RBAC orphan cleanup skipped: no ClusterRole or ClusterRoleBinding was deleted in this run"
  fi
  log INFO "Orphan cleanup summary: found=${ORPHANS_FOUND} kept=${ORPHANS_KEPT} deleted=${ORPHANS_DELETED} failed=${ORPHANS_FAILED} dry_run=${DRY_RUN}"
  [ "${pubsub_ok}" = "true" ] && [ "${rbac_ok}" = "true" ]
}

# A skipped kind must not stop the namespace rule, so remember it and fail the
# run after the namespace rule has run.
ORPHANS_STATUS=0
if [ "${ORPHANS_ENABLED}" = "true" ] && ! sweep_orphans; then
  ORPHANS_STATUS=1
fi

# --- Delete stale namespaces (non-blocking) ---
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

if [ "${ORPHANS_STATUS}" -ne 0 ]; then
  log ERROR "Exiting with an error: an orphan kind was skipped"
  exit 1
fi
