# Wristband signing-key lifecycle tools

This directory defines the image that will replace the legacy Bitnami kubectl
image used by the `hyperfleet-gateway` chart's wristband signing-key hooks
(`wristband-key-provisioner` and `wristband-key-cleanup`), which may be removed
from the public registry (HYPERFLEET-1761). Until that cutover lands, the chart
still pins the Bitnami image; switching it to this image's digest is the
follow-up change of HYPERFLEET-1761.

## Contents

Exactly what the hooks use, nothing more:

| Tool | Used for |
| --- | --- |
| `bash` | Hook scripts (`/bin/bash -ec`) |
| `openssl` | RSA 3072 PKCS#1 key generation and validation |
| `coreutils` | `mktemp`, `base64`, `head`, `sed`, `umask` |
| `kubectl` | Secret create/get/delete |

The base is `ubi9-minimal` (not the `ubi9-micro` the Go-service standard
prefers) because these are dynamically linked tools that need glibc and their
shared libraries; `ubi9-micro` ships neither a shell nor a package manager.

## Pinning

The base image is pinned by tag and digest. `kubectl` is pinned by version and
per-architecture SHA256 (`KUBECTL_SHA256_AMD64` / `KUBECTL_SHA256_ARM64` in the
`Dockerfile`). The RPMs installed via `microdnf` are not pinned, as in the CI
tools image. There is no Renovate configuration for this image; pins are bumped
by hand.

When bumping `KUBECTL_VERSION`, update both checksums from
`https://dl.k8s.io/release/<version>/bin/linux/<arch>/kubectl.sha256`. Keep the
kubectl minor version within one of the clusters the gateway chart targets.
The arm64 checksum is used by local builds
(`WRISTBAND_TOOLS_PLATFORM=linux/arm64`); Konflux publishes amd64 only until
the org moves its PipelineRuns to multi-arch (`buildah-remote-oci-ta` with
`build-platforms`), which would be a coordinated change across all components.

## Build hermeticity

The build is **not hermetic**: `microdnf` fetches `bash`/`openssl` RPMs from
the Red Hat CDN and `kubectl` is downloaded from `dl.k8s.io` during the image
build (only the base image is digest-pinned). Integrity is still covered —
kubectl is verified against its per-architecture SHA256 before install — but
the build needs network access. This matches `ci/tools`, which the org builds
outside Konflux; the Konflux-built Go services instead prefetch their
dependencies (`gomod`) before the image build. There is no RPM or
Konflux-prefetchable source for a pinned `kubectl`, so hermeticity is out of
scope unless the Konflux owners require it; the fallback would be vendoring
the kubectl binaries into this directory.

## Build and check

```bash
make build-wristband-tools   # podman or docker; set CONTAINER_TOOL to choose
make test-wristband-tools    # build, then run the hook operations as UID 1001
```

`test-wristband-tools` runs the image as UID 1001 with a read-only root
filesystem, like the hook securityContext, but with a tmpfs `/tmp` standing in
for the chart Job's `HOME=/work` `emptyDir` mount — it is an image-level check,
not a chart-runtime one. It repeats the key generation, validation and
Secret-rendering operations the provisioner performs; the Dockerfile also
smoke-tests those operations at build time. The exact chart runtime (real
securityContext, `/work` mount, RBAC and hook scripts) is exercised on kind by
`scripts/test-wristband-hooks.sh`.

## Konflux

The `hyperfleet-infra-wristband-tools` Konflux component builds this directory
(PipelineRuns in `.tekton/`) for `linux/amd64` — single-platform, like every
other HyperFleet component (the org's PipelineRuns use `buildah-oci-ta`
without `build-platforms`) — publishing to
`quay.io/redhat-user-workloads/hyperfleet-tenant/hyperfleet/hyperfleet-infra-wristband-tools`
and promoting to
`quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-infra-wristband-tools`
on release.

The component belongs to its own `hyperfleet-infra` Application — not the
`hyperfleet` product Application of ADR-0014, whose single auto-release RPA is
scoped to the service components. The precedent is `hyperfleet-charts`, the
Application the org uses for chart artifacts. Consequence: promotion requires
a ReleasePlan and ReleasePlanAdmission for `hyperfleet-infra` that do not
exist yet and must be created by the Konflux owners when the component is
registered; until then builds publish to `redhat-user-workloads` but nothing
is released.

The chart pins the promoted image **by digest** in
`helm/hyperfleet-gateway/values.yaml` (`auth.wristband.lifecycle.image`). Until
the cutover change of HYPERFLEET-1761 lands, that pin still points at the
legacy `bitnami/kubectl` image; switching it to the first promoted digest of
this image is the follow-up to this work. Bump the pin whenever a new image is
released.

## Full hook behavior

Image-level tests cover key creation and validation. The full hook behavior —
key creation, preservation on upgrade, rejection of invalid existing secrets,
and cleanup on uninstall — is exercised on a local kind cluster by
`scripts/test-wristband-hooks.sh`, which renders the gateway chart in
`EDGE+API` mode with this image, applies the hook resources and checks all
four scenarios.
