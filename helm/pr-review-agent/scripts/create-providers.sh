#!/usr/bin/env bash
# Create or update the credential providers of the PR review agent on its
# OpenShell gateway, with the administrator service account that
# bootstrap-gateway.sh wrote to the env file.
#
# Providers:
#   hyperfleet-vertex  google-vertex-ai, from the local gcloud Application
#                      Default Credentials (run `gcloud auth application-default
#                      login` first); recreated on every run so the refresh
#                      material is current
#   hfreview-github    GitHub token, prompted (or GH_TOKEN in the environment)
#   hfreview-jira      Jira Cloud email and API token, prompted (or
#                      JIRA_BASIC_AUTH=email:token in the environment)
#
# Secrets are read without echo and reach the CLI container only through its
# environment. Existing GitHub and Jira providers are updated in place.
#
# Requirements: podman (or CONTAINER_ENGINE) able to run amd64 images.
#
# Usage: create-providers.sh --admin-env-file PATH [--workspace default]
#          [--vertex-project hypershell-976970] [--vertex-region global]
#          [--cli-image IMAGE] [--insecure true|false]
#          [--skip-vertex] [--skip-github] [--skip-jira]

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
chart_dir=$(dirname -- "$script_dir")

admin_env_file=""
workspace=default
vertex_project=""
vertex_region=""
cli_image=""
insecure=""
skip_vertex=false
skip_github=false
skip_jira=false
engine=${CONTAINER_ENGINE:-podman}

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

while (( $# > 0 )); do
  case "$1" in
    --admin-env-file) admin_env_file=${2:?}; shift 2 ;;
    --workspace) workspace=${2:?}; shift 2 ;;
    --vertex-project) vertex_project=${2:?}; shift 2 ;;
    --vertex-region) vertex_region=${2:?}; shift 2 ;;
    --cli-image) cli_image=${2:?}; shift 2 ;;
    --insecure) insecure=${2:?}; shift 2 ;;
    --skip-vertex) skip_vertex=true; shift ;;
    --skip-github) skip_github=true; shift ;;
    --skip-jira) skip_jira=true; shift ;;
    -h|--help) usage ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done
[[ -n "$admin_env_file" ]] || usage
[[ -r "$admin_env_file" ]] || { printf 'Cannot read %s.\n' "$admin_env_file" >&2; exit 1; }
command -v "$engine" >/dev/null || { printf '%s is not installed.\n' "$engine" >&2; exit 1; }

value_of() {
  grep -E "$1" "$chart_dir/values.yaml" | head -1 | sed -E 's/^[^:]*: *//; s/ *#.*$//; s/^"//; s/"$//'
}
[[ -n "$cli_image" ]] || cli_image=$(value_of '^  image: quay.io/opendatahub/odh-openshell-cli')
[[ -n "$insecure" ]] || insecure=$(value_of '^  insecure: ')
[[ -n "$vertex_project" ]] || vertex_project=$(value_of '^    projectId: ')
[[ -n "$vertex_region" ]] || vertex_region=$(value_of '^    region: ')

gcloud_dir="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}"
if [[ "$skip_vertex" != true && ! -r "$gcloud_dir/application_default_credentials.json" ]]; then
  printf 'No gcloud Application Default Credentials in %s. Run: gcloud auth application-default login\n' \
    "$gcloud_dir" >&2
  exit 1
fi

if [[ "$skip_github" != true && -z "${GH_TOKEN:-}" ]]; then
  read -r -s -p 'GitHub token for the review account: ' GH_TOKEN
  printf '\n'
fi
if [[ "$skip_jira" != true && -z "${JIRA_BASIC_AUTH:-}" ]]; then
  read -r -p 'Jira email: ' jira_email
  read -r -s -p 'Jira API token: ' jira_token
  printf '\n'
  JIRA_BASIC_AUTH="$jira_email:$jira_token"
  unset jira_email jira_token
fi
export GH_TOKEN JIRA_BASIC_AUTH

# The single-quoted script runs inside the container with its own variables.
# shellcheck disable=SC2016
"$engine" run --rm -i --platform linux/amd64 --entrypoint /usr/bin/bash \
  --env-file "$admin_env_file" \
  -e "OPENSHELL_GATEWAY_INSECURE=$insecure" -e RUST_LOG=error -e NO_COLOR=1 \
  -e HOME=/home/1000 -e XDG_CONFIG_HOME=/tmp/cfg -e XDG_STATE_HOME=/tmp/state -e OPENSHELL_NO_BROWSER=1 \
  -e "WORKSPACE=$workspace" -e "VERTEX_PROJECT=$vertex_project" -e "VERTEX_REGION=$vertex_region" \
  -e "SKIP_VERTEX=$skip_vertex" -e "SKIP_GITHUB=$skip_github" -e "SKIP_JIRA=$skip_jira" \
  -e GH_TOKEN -e JIRA_BASIC_AUTH \
  -v "$gcloud_dir:/home/1000/.config/gcloud:ro" \
  "$cli_image" -c '
set -euo pipefail
mkdir -p /tmp/cfg /tmp/state
openshell gateway add "$GATEWAY_ENDPOINT" --name gw --oidc-issuer "$OIDC_ISSUER" \
  --oidc-client-id "$OIDC_CLIENT_ID" --oidc-audience "$OIDC_AUDIENCE" >/dev/null
openshell gateway login gw >/dev/null
existing=$(openshell provider list --workspace "$WORKSPACE" 2>/dev/null | awk "NR > 1 { print \$1 }")
has() { grep --line-regexp --quiet --fixed-strings -- "$1" <<<"$existing"; }

if [[ "$SKIP_VERTEX" != true ]]; then
  if has hyperfleet-vertex; then
    printf "Recreate hyperfleet-vertex with the current gcloud credentials.\n"
    openshell provider delete --workspace "$WORKSPACE" hyperfleet-vertex >/dev/null
  fi
  openshell provider create --workspace "$WORKSPACE" --name hyperfleet-vertex \
    --type google-vertex-ai --from-gcloud-adc \
    --config "VERTEX_AI_PROJECT_ID=$VERTEX_PROJECT" --config "VERTEX_AI_REGION=$VERTEX_REGION"
fi
if [[ "$SKIP_GITHUB" != true ]]; then
  if has hfreview-github; then
    openshell provider update --workspace "$WORKSPACE" --credential GH_TOKEN hfreview-github
  else
    openshell provider create --workspace "$WORKSPACE" --name hfreview-github \
      --type hfreview-github --credential GH_TOKEN
  fi
fi
if [[ "$SKIP_JIRA" != true ]]; then
  if has hfreview-jira; then
    openshell provider update --workspace "$WORKSPACE" --credential JIRA_BASIC_AUTH hfreview-jira
  else
    openshell provider create --workspace "$WORKSPACE" --name hfreview-jira \
      --type hfreview-jira --credential JIRA_BASIC_AUTH
  fi
fi
printf "\n"
openshell provider list --workspace "$WORKSPACE"
if [[ "$SKIP_VERTEX" != true ]]; then
  openshell provider refresh status --workspace "$WORKSPACE" hyperfleet-vertex | cut -c1-120
fi
'
unset GH_TOKEN JIRA_BASIC_AUTH
