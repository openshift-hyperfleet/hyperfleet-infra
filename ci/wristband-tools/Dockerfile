# Wristband signing-key lifecycle image.
#
# Replacement for the legacy Bitnami kubectl image consumed by the
# hyperfleet-gateway chart's wristband-key-provisioner and
# wristband-key-cleanup hooks, which may be removed from the public registry.
# The chart switches to this image in a follow-up change of HYPERFLEET-1761,
# once its first release is promoted. Contains exactly what those hooks use:
# bash, coreutils, openssl and kubectl.
#
# Konflux builds linux/amd64 today, like every other HyperFleet component (the
# org's PipelineRuns use single-platform buildah-oci-ta). The arm64 checksum
# below is not dead weight: local multi-arch builds work
# (make build-wristband-tools WRISTBAND_TOOLS_PLATFORM=linux/arm64) and a
# future switch to multi-arch Konflux builds only needs the PipelineRun change.
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.8-1793862054@sha256:4b79c93106c14ad1c234907f83441ff0e4f8d24e78426a36e159098e9f7e6fa5

SHELL ["/bin/bash", "-o", "errexit", "-o", "nounset", "-o", "pipefail", "-c"]

ARG KUBECTL_VERSION=v1.34.13
# Per-architecture SHA256 checksums from
# https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/<arch>/kubectl.sha256
ARG KUBECTL_SHA256_AMD64=b4bb494e9466a7a94bb851414548bc0d3e2f8da90757e6eccc3371e648648591
ARG KUBECTL_SHA256_ARM64=66e8283d52d9bc1f9c0e9daade7c971cd20db5a379306862897dfb25395f3e03
ARG TARGETARCH

USER root
# ubi-minimal already ships coreutils-single and curl-minimal, which provide
# every coreutils binary and curl the hooks use; installing the full packages
# conflicts with them.
RUN microdnf install -y bash openssl \
    && microdnf clean all \
    && case "${TARGETARCH}" in \
         amd64) kubectl_sha="${KUBECTL_SHA256_AMD64}" ;; \
         arm64) kubectl_sha="${KUBECTL_SHA256_ARM64}" ;; \
         *) echo "ERROR: unsupported architecture ${TARGETARCH}" >&2; exit 1 ;; \
       esac \
    && curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
    && echo "${kubectl_sha}  /usr/local/bin/kubectl" | sha256sum -c - \
    && chmod 755 /usr/local/bin/kubectl \
    && rm -rf /var/cache/dnf

# The chart hooks run as non-root with runAsUser/runAsGroup/fsGroup 1001 and a
# read-only root filesystem; keep the image consistent with that.
ENV HOME=/tmp
USER 1001:1001

# Smoke-test the exact operations the chart hooks perform, as the user the
# hooks run as: generate a PKCS#1 3072-bit RSA key the way the provisioner does
# (openssl genrsa -traditional, umask 077), validate it the way its
# validate_existing_secret function does, and render the Secret it creates
# (client-side dry-run needs no cluster).
RUN work_dir="$(mktemp -d)" \
    && key_file="$(mktemp "${work_dir}/wristband-key.XXXXXX")" \
    && trap 'rm -rf "${work_dir}"' EXIT \
    && umask 077 \
    && openssl genrsa -traditional -out "${key_file}" 3072 >/dev/null 2>&1 \
    && [[ $(head -n 1 "${key_file}") == "-----BEGIN RSA PRIVATE KEY-----" ]] \
    && openssl rsa -in "${key_file}" -check -noout >/dev/null \
    && key_bits="$(openssl rsa -in "${key_file}" -noout -text 2>/dev/null \
        | sed -n 's/^Private-Key: (\([0-9][0-9]*\) bit.*/\1/p')" \
    && [[ "${key_bits}" == "3072" ]] \
    && kubectl create secret generic wristband-test-key \
        --from-file=key.pem="${key_file}" --dry-run=client -o yaml \
        | grep -q 'key.pem: ' \
    && kubectl version --client >/dev/null

# Metadata last so an APP_VERSION bump only rebuilds the label layer, not the
# microdnf, kubectl and smoke-test layers.
ARG APP_VERSION="0.0.0-dev"
LABEL name="hyperfleet-infra-wristband-tools" \
      vendor="Red Hat, Inc." \
      version="${APP_VERSION}" \
      summary="Wristband signing-key lifecycle tools" \
      description="bash, openssl and kubectl for the hyperfleet-gateway wristband signing-key hooks" \
      org.opencontainers.image.source="https://github.com/openshift-hyperfleet/hyperfleet-infra"
