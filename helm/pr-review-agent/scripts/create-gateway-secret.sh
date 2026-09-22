#!/usr/bin/env bash
# Create the gateway Secret of the pull request review agent from the
# credential bundle that `hsctl create serviceAccount --output-file` writes.
# The script does not print the client secret.

set -euo pipefail
umask 077

usage() {
  printf 'Usage: %s <credential-bundle.json> [namespace] [secret-name]\n' "$0" >&2
  exit 2
}

[[ $# -ge 1 && $# -le 3 ]] || usage
readonly bundle=$1
readonly namespace=${2:-pr-review-agent}
readonly secret_name=${3:-pr-review-gateway}

for tool in jq kubectl; do
  command -v "$tool" >/dev/null || { printf '%s is not installed.\n' "$tool" >&2; exit 1; }
done
[[ -r "$bundle" ]] || { printf 'Cannot read %s.\n' "$bundle" >&2; exit 1; }

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

# Secret key -> field of the `credential` object in the bundle.
fields=(
  gateway-endpoint:gateway_endpoint
  oidc-issuer:issuer
  oidc-client-id:client_id
  oidc-audience:audience
  oidc-client-secret:client_secret
)
from_file_args=()
for field in "${fields[@]}"; do
  key=${field%%:*}
  name=${field#*:}
  if ! jq --exit-status --join-output --arg name "$name" \
    '.credential[$name] | select(type == "string" and length > 0)' \
    "$bundle" >"$work_dir/$key"; then
    printf 'The bundle has no credential.%s value.\n' "$name" >&2
    if [[ "$name" == gateway_endpoint ]]; then
      printf 'The gateway has not published an endpoint yet.\n' >&2
    fi
    exit 1
  fi
  from_file_args+=("--from-file=$key=$work_dir/$key")
done

kubectl get namespace "$namespace" >/dev/null 2>&1 || kubectl create namespace "$namespace"
kubectl create secret generic "$secret_name" --namespace "$namespace" \
  "${from_file_args[@]}" --dry-run=client --output=yaml | kubectl apply -f - >/dev/null

printf 'Secret %s/%s is ready.\n' "$namespace" "$secret_name"
printf 'Service account subject for the workspace member grant: %s\n' \
  "$(jq --raw-output '.subject // "unknown"' "$bundle")"
printf 'Credential expiry: %s\n' "$(jq --raw-output '.expires_at // "unknown"' "$bundle")"
printf 'Delete %s now. HyperShell cannot return the client secret again.\n' "$bundle"
