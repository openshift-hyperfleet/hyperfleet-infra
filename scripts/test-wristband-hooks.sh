#!/usr/bin/env bash
# Exercise the hyperfleet-gateway wristband signing-key hooks on a kind
# cluster with the locally built wristband-tools image.
#
# Covers the four acceptance-criteria scenarios:
#   1. creation:    no Secret -> provisioner creates a valid one
#   2. preservation: valid Secret -> provisioner leaves it untouched
#   3. validation:  invalid Secret -> provisioner fails without modifying it
#   4. cleanup:     cleanup hook deletes the Secret
#
# The chart's hook resources are rendered with the local image override and
# applied directly with kubectl (the helm.sh/hook annotations are inert under
# kubectl), so the exact chart templates, RBAC and scripts run as shipped.
#
# Usage: scripts/test-wristband-hooks.sh
# Requires: kind cluster as current kubectl context, kind, kubectl, openssl,
# make, podman or docker, yq, helm.
set -euo pipefail

CHART_DIR="helm/hyperfleet-gateway"
IMAGE="${WRISTBAND_TOOLS_IMAGE:-localhost/hyperfleet-infra-wristband-tools:dev}"
NAMESPACE="${WRISTBAND_HOOK_TEST_NAMESPACE:-wristband-hooks-test}"
SECRET_NAME="wristband-test-key"
RELEASE="wristband-test"
CONTAINER_TOOL="${CONTAINER_TOOL:-$(command -v podman 2>/dev/null || command -v docker 2>/dev/null || true)}"

fail() { echo "  ✗ FAIL: $1" >&2; exit 1; }
pass() { echo "  ✓ $1"; }

# The Makefile runs from the repo root; allow running from anywhere.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "━━━ Wristband hook tests (${IMAGE} on ${NAMESPACE}) ━━━"

# ─── Pre-flight ─────────────────────────────────────────────────────
[[ "$(kubectl config current-context)" == kind-* ]] \
  || fail "current kubectl context is not a kind cluster (got $(kubectl config current-context))"
command -v yq >/dev/null || fail "yq not found"
command -v helm >/dev/null || fail "helm not found"
command -v kind >/dev/null || fail "kind not found"
command -v kubectl >/dev/null || fail "kubectl not found"
command -v openssl >/dev/null || fail "openssl not found"
[[ -n "$CONTAINER_TOOL" ]] || fail "no container tool found (podman/docker)"

echo "Building and loading ${IMAGE} into kind..."
# Native platform by default (kind nodes run the host architecture); mirrors
# detect_platform() in kind-build-images.sh. The Makefile exports
# WRISTBAND_TOOLS_PLATFORM with the same native default.
detect_platform() {
  case "$(uname -m)" in
    x86_64) echo "linux/amd64" ;;
    aarch64|arm64) echo "linux/arm64" ;;
    *) echo "linux/amd64" ;;
  esac
}
PLATFORM="${WRISTBAND_TOOLS_PLATFORM:-$(detect_platform)}"
# Build through the Makefile target so this script and
# `make build-wristband-tools` produce the same image (same APP_VERSION stamp).
make --no-print-directory build-wristband-tools \
  WRISTBAND_TOOLS_IMAGE="$IMAGE" \
  WRISTBAND_TOOLS_PLATFORM="$PLATFORM" \
  WRISTBAND_TOOLS_DIR="${WRISTBAND_TOOLS_DIR:-ci/wristband-tools}"
# Cluster name comes from the current context (kind-<name>). KIND_CLUSTER_NAME
# is deliberately not honored: the Makefile exports env.kind's default
# (KIND_CLUSTER_NAME ?= kind), which would win over the real cluster name.
cluster="$(kubectl config current-context | sed 's/^kind-//')"
if [[ "$(basename "$CONTAINER_TOOL")" == "podman" ]]; then
  "$CONTAINER_TOOL" save "$IMAGE" | kind load image-archive /dev/stdin --name "$cluster"
else
  kind load docker-image "$IMAGE" --name "$cluster"
fi

# ─── Render the chart's hook resources with the local image ─────────
render() {
  helm template "$RELEASE" "$CHART_DIR" \
    --namespace "$NAMESPACE" \
    --set auth.mode=EDGE+API \
    --set "auth.wristband.lifecycle.image=${IMAGE}" \
    --set "auth.wristband.signingKeySecretName=${SECRET_NAME}" \
    --set-json 'auth.identityProviders=[{"name":"human-jwt","issuerUrl":"https://idp.example.com","audience":"hyperfleet-api","identityClaim":"sub"}]'
}

# Extract the hook manifests by name suffix: picks the ServiceAccount, Role,
# RoleBinding and Job whose metadata.name ends in -wristband-key-<hook>.
hook_manifests() { # $1: provisioner|cleanup
  render | yq "select(.metadata.name != null and (.metadata.name | test(\"-wristband-key-${1}$\")))"
}

# Run one hook Job (RBAC first) and wait for it to finish. Prints "ok" when
# the Job succeeded, "failed" when it failed and "timeout" when it did not
# finish within 120s; callers map each value to a distinct failure message.
run_hook() { # $1: provisioner|cleanup
  local hook="$1" job
  kubectl -n "$NAMESPACE" delete jobs --all --ignore-not-found=true >/dev/null 2>&1
  hook_manifests "$hook" | kubectl -n "$NAMESPACE" apply -f - >/dev/null
  job="$(hook_manifests "$hook" | yq 'select(.kind == "Job") | .metadata.name')"
  for _ in $(seq 1 60); do
    if kubectl -n "$NAMESPACE" get job "$job" -o jsonpath='{.status.succeeded}' 2>/dev/null | grep -q 1; then
      echo "ok"; return 0
    fi
    if kubectl -n "$NAMESPACE" get job "$job" -o jsonpath='{.status.failed}' 2>/dev/null | grep -qE '[1-9]'; then
      echo "failed"; return 0
    fi
    sleep 2
  done
  echo "timeout"
}

secret_key() { kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" -o 'jsonpath={.data.key\.pem}' 2>/dev/null; }

# ─── Fresh namespace ────────────────────────────────────────────────
# The namespace is labeled on creation and only a labeled one is reused or
# deleted, so a WRISTBAND_HOOK_TEST_NAMESPACE override cannot make this script
# destroy a namespace it does not own.
NAMESPACE_LABEL="hyperfleet-wristband-test=true"

cleanup() {
  # Re-check ownership before deleting: the namespace may belong to another
  # actor (created after the guard below) or this run may have died before
  # labeling it. Either way, only a labeled namespace is ours to delete.
  if [[ "$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.hyperfleet-wristband-test}' 2>/dev/null)" == "true" ]]; then
    kubectl delete namespace "$NAMESPACE" --ignore-not-found=true >/dev/null
  fi
}

if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  if [[ "$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.hyperfleet-wristband-test}')" != "true" ]]; then
    fail "namespace ${NAMESPACE} exists but is not owned by this script (missing ${NAMESPACE_LABEL}); delete it manually or pick another WRISTBAND_HOOK_TEST_NAMESPACE"
  fi
  kubectl delete namespace "$NAMESPACE" --wait=true >/dev/null
fi
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
# Create and label in one apply, so an interrupted run cannot leave an
# unlabeled namespace behind that the next run would refuse to touch.
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml \
  | kubectl label --local --overwrite -f - "$NAMESPACE_LABEL" --dry-run=client -o yaml \
  | kubectl apply -f - >/dev/null

# ─── Scenario 1: creation ───────────────────────────────────────────
echo ""
echo "Scenario 1: provisioner creates the signing Secret"
status="$(run_hook provisioner)"
[[ "$status" == "ok" ]] || fail "provisioner job did not create the Secret (status: ${status})"
[[ -n "$(secret_key)" ]] || fail "Secret ${SECRET_NAME} was not created"
secret_key | base64 -d | openssl rsa -check -noout >/dev/null 2>&1 \
  || fail "created Secret does not hold a valid RSA private key"
key_created="$(secret_key)"
pass "Secret created with a valid RSA key"

# ─── Scenario 2: preservation ───────────────────────────────────────
echo ""
echo "Scenario 2: provisioner preserves an existing valid Secret"
status="$(run_hook provisioner)"
[[ "$status" == "ok" ]] || fail "provisioner job did not succeed with existing Secret (status: ${status})"
[[ "$(secret_key)" == "$key_created" ]] || fail "existing Secret was modified"
pass "existing valid Secret preserved untouched"

# ─── Scenario 3: validation ─────────────────────────────────────────
echo ""
echo "Scenario 3: provisioner rejects an invalid Secret without modifying it"
garbage="$(printf 'not-a-key' | base64)"
kubectl -n "$NAMESPACE" patch secret "$SECRET_NAME" \
  --type merge -p "{\"data\":{\"key.pem\":\"${garbage}\"}}" >/dev/null
status="$(run_hook provisioner)"
[[ "$status" == "failed" ]] || fail "provisioner did not reject the invalid Secret (status: ${status}, want: failed)"
[[ "$(secret_key)" == "$garbage" ]] || fail "invalid Secret was modified"
pass "invalid Secret rejected and left unmodified"

# ─── Scenario 4: cleanup ────────────────────────────────────────────
echo ""
echo "Scenario 4: cleanup hook deletes the Secret"
status="$(run_hook cleanup)"
[[ "$status" == "ok" ]] || fail "cleanup job did not succeed (status: ${status})"
if kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" >/dev/null 2>&1; then
  fail "Secret still exists after cleanup"
fi
pass "Secret deleted by cleanup hook"

echo ""
echo "━━━ All four wristband hook scenarios passed ━━━"
