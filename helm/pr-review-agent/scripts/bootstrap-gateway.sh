#!/usr/bin/env bash
# Bootstrap (or re-bootstrap) the OpenShell gateway that the PR review agent
# uses, and the Kubernetes Secret that the CronJobs read.
#
# It creates, on the HyperShell instance that hsctl is logged in to:
#   1. the gateway (Route exposure enabled) unless it exists,
#   2. a runner service account (openshell-user) and the Secret on the cluster
#      that KUBECONFIG points to (via create-gateway-secret.sh),
#   3. an administrator service account (openshell-admin) whose credentials
#      go to ADMIN_ENV_FILE,
#   4. with that administrator: workspace membership for the runner and the
#      provider profiles from ../openshell/.
#
# The providers themselves need user credentials (GitHub token, Jira token,
# gcloud ADC) and stay a manual step; the script prints the commands.
#
# Requirements: hsctl (logged in), jq, kubectl, podman (or CONTAINER_ENGINE).
#
# Usage: bootstrap-gateway.sh --cluster <managed-cluster-name-or-id>
#          [--gateway-name hyperfleet-review] [--workspace default]
#          [--namespace pr-review-agent] [--secret pr-review-gateway]
#          [--admin-env-file PATH] [--cli-image IMAGE] [--insecure true|false]

set -euo pipefail
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
chart_dir=$(dirname -- "$script_dir")

cluster=""
gateway_name=hyperfleet-review
workspace=default
namespace=pr-review-agent
secret_name=pr-review-gateway
admin_env_file=""
cli_image=""
insecure=""
engine=${CONTAINER_ENGINE:-podman}

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

while (( $# > 0 )); do
  case "$1" in
    --cluster) cluster=${2:?}; shift 2 ;;
    --gateway-name) gateway_name=${2:?}; shift 2 ;;
    --workspace) workspace=${2:?}; shift 2 ;;
    --namespace) namespace=${2:?}; shift 2 ;;
    --secret) secret_name=${2:?}; shift 2 ;;
    --admin-env-file) admin_env_file=${2:?}; shift 2 ;;
    --cli-image) cli_image=${2:?}; shift 2 ;;
    --insecure) insecure=${2:?}; shift 2 ;;
    -h|--help) usage ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done
[[ -n "$cluster" ]] || usage

for tool in hsctl jq kubectl "$engine"; do
  command -v "$tool" >/dev/null || { printf '%s is not installed.\n' "$tool" >&2; exit 1; }
done

value_of() {
  # Read a scalar from values.yaml: value_of '^  image: ' -> first match.
  grep -E "$1" "$chart_dir/values.yaml" | head -1 | sed -E 's/^[^:]*: *//; s/ *#.*$//; s/^"//; s/"$//'
}
[[ -n "$cli_image" ]] || cli_image=$(value_of '^  image: quay.io/opendatahub/odh-openshell-cli')
[[ -n "$insecure" ]] || insecure=$(value_of '^  insecure: ')
[[ -n "$admin_env_file" ]] || admin_env_file="${TMPDIR:-/tmp}/$gateway_name-admin.env"

log() { printf '==> %s\n' "$*"; }

log "HyperShell identity"
hsctl whoami | grep -E 'User|API URL'

# --- 1. gateway -------------------------------------------------------------
cluster_id=$(hsctl list managedClusters -o json | jq -r --arg c "$cluster" \
  '(.items // .)[] | select(.id == $c or .name == $c) | .id' | head -1)
[[ -n "$cluster_id" ]] || { printf 'Managed cluster %s not found.\n' "$cluster" >&2; exit 1; }

gateway_id=$(hsctl list gateways -o json | jq -r --arg n "$gateway_name" \
  '(.items // .)[] | select(.name == $n) | .id' | head -1)
if [[ -z "$gateway_id" ]]; then
  log "Create gateway $gateway_name on cluster $cluster_id"
  gateway_id=$(hsctl create gateway --name "$gateway_name" --cluster-id "$cluster_id" \
    --route '{"enabled": true}' | jq -r .id)
else
  log "Gateway $gateway_name exists: $gateway_id"
fi
[[ "$gateway_id" =~ ^[A-Za-z0-9]+$ ]] || { printf 'Invalid gateway ID.\n' >&2; exit 1; }

log "Wait for the gateway to run and publish its route"
for _ in $(seq 1 60); do
  gateway_json=$(hsctl get gateway "$gateway_id")
  phase=$(jq -r '.phase // ""' <<<"$gateway_json")
  route_address=$(jq -r '.route_address // ""' <<<"$gateway_json")
  route_enabled=$(jq -r '.route // "" | try fromjson catch {} | .enabled // false' <<<"$gateway_json")
  if [[ "$route_enabled" != true ]]; then
    printf 'kind: Gateway\nmetadata:\n  name: %s\nspec:\n  route: %s\n' \
      "$gateway_name" "'{\"enabled\": true}'" | hsctl apply -f - >/dev/null
  fi
  [[ "$phase" == Running && -n "$route_address" ]] && break
  sleep 10
done
[[ "$phase" == Running && -n "$route_address" ]] || {
  printf 'Gateway %s is %s with route %q after 10 minutes.\n' "$gateway_id" "$phase" "$route_address" >&2
  exit 1
}
log "Gateway $gateway_id is Running at $route_address"

# --- 2. runner service account + Secret -------------------------------------
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
log "Create runner service account"
hsctl create serviceAccount --gateway-id "$gateway_id" --name hyperfleet-pr-review \
  --description "PR review CronJobs ($namespace)" --role openshell-user --expires-in 365d \
  --output-file "$work_dir/runner.json" >/dev/null
runner_subject=$(jq -r .subject "$work_dir/runner.json")
"$script_dir/create-gateway-secret.sh" "$work_dir/runner.json" "$namespace" "$secret_name"
rm -f "$work_dir/runner.json"

# --- 3. administrator service account ---------------------------------------
log "Create administrator service account"
hsctl create serviceAccount --gateway-id "$gateway_id" --name hyperfleet-review-admin \
  --description "Gateway administration for the PR review agent" --role openshell-admin \
  --expires-in 365d --output-file "$work_dir/admin.json" >/dev/null
jq -r '"GATEWAY_ENDPOINT=\(.credential.gateway_endpoint)\nOIDC_ISSUER=\(.credential.issuer)\nOIDC_CLIENT_ID=\(.credential.client_id)\nOIDC_AUDIENCE=\(.credential.audience)\nOPENSHELL_OIDC_CLIENT_SECRET=\(.credential.client_secret)\nSERVICE_ACCOUNT_SUBJECT=\(.subject)"' \
  "$work_dir/admin.json" >"$admin_env_file"
rm -f "$work_dir/admin.json"
chmod 0600 "$admin_env_file"
log "Administrator credentials: $admin_env_file"

# --- 4. workspace membership and provider profiles --------------------------
log "Grant workspace membership and import provider profiles (workspace $workspace)"
# The single-quoted script runs inside the container with its own variables.
# shellcheck disable=SC2016
"$engine" run --rm --platform linux/amd64 --entrypoint /usr/bin/bash \
  --env-file "$admin_env_file" \
  -e "OPENSHELL_GATEWAY_INSECURE=$insecure" -e RUST_LOG=error -e NO_COLOR=1 \
  -e HOME=/tmp -e XDG_CONFIG_HOME=/tmp/cfg -e XDG_STATE_HOME=/tmp/state -e OPENSHELL_NO_BROWSER=1 \
  -e "WORKSPACE=$workspace" -e "RUNNER_SUBJECT=$runner_subject" \
  -v "$chart_dir/openshell:/profiles:ro" \
  "$cli_image" -c '
set -euo pipefail
mkdir -p /tmp/cfg /tmp/state
openshell gateway add "$GATEWAY_ENDPOINT" --name gw --oidc-issuer "$OIDC_ISSUER" \
  --oidc-client-id "$OIDC_CLIENT_ID" --oidc-audience "$OIDC_AUDIENCE" >/dev/null
openshell gateway login gw >/dev/null
openshell workspace member add --workspace "$WORKSPACE" --subject "$RUNNER_SUBJECT" --role user
for profile in /profiles/*.yaml; do
  name=$(sed -n "s/^id: //p" "$profile")
  if openshell provider profile export "$name" --workspace "$WORKSPACE" >/dev/null 2>&1; then
    printf "Profile %s exists.\n" "$name"
  else
    openshell provider profile import --workspace "$WORKSPACE" --file "$profile"
  fi
done
openshell provider profile list --workspace "$WORKSPACE"
'

cat <<MSG

Gateway $gateway_name ($gateway_id) is ready. Create the providers (GitHub
token, Jira token, gcloud ADC) with the administrator credentials, then install
the releases:

  $script_dir/create-providers.sh --admin-env-file $admin_env_file
  make install-pr-review-agents
MSG
