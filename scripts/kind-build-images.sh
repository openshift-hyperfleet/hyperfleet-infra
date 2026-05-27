#!/usr/bin/env bash

set -euo pipefail

PROJECTS_DIR="${PROJECTS_DIR:-${HOME}/openshift-hyperfleet}"
APP_VERSION="${APP_VERSION:-"0.0.0-dev"}"
# Set with env.kind
: "${REGISTRY:?REGISTRY must be set and non-empty}"
: "${API_IMAGE_TAG:?API_IMAGE_TAG must be set and non-empty}"
: "${SENTINEL_IMAGE_TAG:?SENTINEL_IMAGE_TAG must be set and non-empty}"
: "${ADAPTER_IMAGE_TAG:?ADAPTER_IMAGE_TAG must be set and non-empty}"
: "${KIND_CLUSTER_NAME:?KIND_CLUSTER_NAME must be set and non-empty}"


detect_platform() {
  case "$(uname -m)" in
    x86_64)  echo "linux/amd64" ;;
    aarch64|arm64) echo "linux/arm64" ;;
    *) echo "linux/amd64" ;;
  esac
}

PLATFORM="${PLATFORM:-$(detect_platform)}"

if [[ ! -d "${PROJECTS_DIR}" ]]; then
  echo "[ERROR] PROJECTS_DIR does not exist: ${PROJECTS_DIR}"
  echo "Set PROJECTS_DIR to the parent directory containing your repos."
  exit 1
fi

CONTAINER_TOOL="${CONTAINER_TOOL:-$(command -v podman 2>/dev/null || command -v docker 2>/dev/null || true)}"


if [[ -z "${CONTAINER_TOOL}" ]]; then
  echo "[ERROR] No container tool found (podman or docker). Install one or set CONTAINER_TOOL."
  exit 1
fi

REPO_PREFIX="hyperfleet-"
COMPONENTS=(api sentinel adapter)

component_repo() {
    echo "${REPO_PREFIX}${1}"
}

component_image_tag() {
    local tag_var
    tag_var="$(echo "${1}" | tr '[:lower:]' '[:upper:]')_IMAGE_TAG"
    echo "${!tag_var:-local}"
}

echo "=== Building HyperFleet images and loading into kind cluster: ${KIND_CLUSTER_NAME} ==="

for component in "${COMPONENTS[@]}"; do
    repo="$(component_repo "${component}")"
    dir="${PROJECTS_DIR}/${repo}"
    if [[ ! -d "${dir}" ]]; then
        echo "[ERROR] ${repo} not found at ${dir}"
        echo "        Clone it: git clone https://github.com/openshift-hyperfleet/${repo}.git ${dir}"
        echo "        Or set PROJECTS_DIR to the parent directory containing your repos."
        exit 1
    fi
    echo "Building ${component} (${repo}) from ${dir}"
    cd "${dir}"
    make image \
        IMAGE_REGISTRY="${REGISTRY}" \
        IMAGE_TAG="$(component_image_tag "${component}")" \
        APP_VERSION="${APP_VERSION}" \
        PLATFORM="${PLATFORM}"
    cd - > /dev/null
    image_ref="${REGISTRY}/${repo}:$(component_image_tag "${component}")"
    echo "[LOAD]  ${image_ref} -> kind cluster: ${KIND_CLUSTER_NAME}"
    if [[ "$(basename "${CONTAINER_TOOL}")" == "podman" ]]; then
        "${CONTAINER_TOOL}" save "${image_ref}" | kind load image-archive /dev/stdin --name "${KIND_CLUSTER_NAME}"
    else
        kind load docker-image "${image_ref}" --name "${KIND_CLUSTER_NAME}"
    fi
done

