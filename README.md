# HyperFleet Infrastructure

Infrastructure as Code for HyperFleet development environments using **Makefile + Helmfile + Terraform**.

`make help` is the canonical entry point.

## Overview

Two message broker backends are supported:

- **Google Pub/Sub** (default) — managed by GCP, provisioned via Terraform
- **RabbitMQ** — self-hosted via `helm/rabbitmq/`, used for kind/local deployments

**Terraform manages (GCP only):**

- Shared VPC, subnets, firewall rules (one-time per project)
- Per-developer GKE clusters
- Google Pub/Sub topics, subscriptions, Workload Identity
- Helm values files written to `generated-values-from-terraform/`

**Helmfile manages:**

- All HyperFleet components (API, Sentinels, Adapters, *RabbitMQ)
- Environment-specific configurations across four environments

## Prerequisites

### All environments

- `helm` + [`helm-git` plugin](https://github.com/aslafy-z/helm-git) + [`helm-diff` plugin](https://github.com/databus23/helm-diff)
- `helmfile`
- `kubectl` with a configured context

```bash
helm plugin install https://github.com/aslafy-z/helm-git
helm plugin install https://github.com/databus23/helm-diff --verify=false
```

### GCP only

- `terraform 1.17.2` (pinned via `.tool-versions`; use [asdf](https://asdf-vm.com/))
- [Google Cloud SDK](https://cloud.google.com/sdk/docs/install) (`gcloud`) + `gke-gcloud-auth-plugin`
- Access to the `hcm-hyperfleet` GCP project

### OCI external-dns (optional)

The OCI external-dns addon is disabled by default. It uses instance principals on OKE worker nodes to publish records for Kubernetes Services. For Helmfile configuration and installation usage, see [`helm/external-dns/README.md`](helm/external-dns/README.md). For OCI DNS resource configuration, see [`terraform/oci/README.md`](terraform/oci/README.md).

### kind only

- `kind`
- `podman` or `docker` (for image builds)

## Deployment Environments

| `HELMFILE_ENV` | Cluster | Broker | Notes |
| ---------------- | --------- | -------- | ------- |
| `gcp` | GKE (Terraform) | Google Pub/Sub | Requires Terraform-generated values |
| `kind` | kind (local) | RabbitMQ | Requires script-generated values |
| `e2e-gcp` | GKE (Terraform) | Google Pub/Sub | Broker config hardcoded in helmfile |
| `e2e-kind` | kind (local) | RabbitMQ | Broker config hardcoded in helmfile |

`HELMFILE_ENV` defaults to `gcp` if not set.

### E2E fixture entities

`e2e-kind` and `e2e-gcp` load `fixtureEntities` from
[`helmfile/environments/e2e/fixture-entities.yaml`](helmfile/environments/e2e/fixture-entities.yaml).
These five test-only types are appended to the five production types in the API's
`config.entities`; they define resource types, not individual test resources.

| Kind | Plural | Parent / delete policy | Reference | Sentinel |
| ---- | ------ | ---------------------- | --------- | -------- |
| Parent | `parents` | Root | None | `parents` |
| CascadeChild | `cascadechildren` | Parent / cascade | None | `cascadechildren` |
| RestrictChild | `restrictchildren` | Parent / restrict | None | None |
| Referencer | `referencers` | Root | Optional `target` → Target, at most one | None |
| Target | `targets` | Root | None | None |

Both E2E environments have ten entity types and four Sentinels. The CascadeChild
Sentinel includes the parent's owner references in its events, as NodePool does.
`kind` and `gcp` retain five entity types and two Sentinels, and reject nonempty
`fixtureEntities` overrides.

For every entity, `required_adapters` is derived from adapter entries whose
`resourceType` matches its plural. No match renders an empty list. The fixture
success adapters are separate work (HYPERFLEET-1729); until they are configured,
fixture creation verifies API routing, not adapter-backed reconciliation.

Run `make validate-fixture-entities` to render and check all four environments.
It uses temporary broker values and mocked Kubernetes OIDC discovery, so it does
not need a cluster or alter generated values in the repository. Chart downloads
still require network access; `API_CHART_REF` and `SENTINEL_CHART_REF` select their
revisions. This check is included in `make ci-dry-run`.

### Environment variable loading

The Makefile selects the env file based on `HELMFILE_ENV`:

- contains `gcp` → sources `env.gcp`
- does not contain `gcp` → sources `env.kind` (so `kind`, `e2e-kind`, etc.)

All variables use `?=`. CLI overrides always win:

```bash
HELMFILE_ENV=kind NAMESPACE=my-namespace REGISTRY=quay.io make install-hyperfleet
```

Configuration precedence (highest to lowest):

1. CLI variables
2. `env.gcp` or `env.kind`
3. Makefile defaults

## Makefile Targets

### HyperFleet

| Target | Description |
| -------- | ------------- |
| `make install-hyperfleet` | Install all HyperFleet components |
| `make install-gateway` | Install or update HyperFleet gateway (Gateway API resources), Authorino, and AuthConfig only |
| `make install-api` | Install HyperFleet API only |
| `make install-sentinels` | Install Sentinels only |
| `make install-adapters` | Install Adapters only |
| `make install-desire-delivery` | Install the desire delivery stack only (Redis + the applier) |
| `make uninstall-hyperfleet` | Uninstall all HyperFleet components |
| `make uninstall-api` | Uninstall API only |
| `make uninstall-sentinels` | Uninstall Sentinels only |
| `make uninstall-adapters` | Uninstall Adapters only |
| `make uninstall-desire-delivery` | Uninstall the desire delivery stack only (Redis + the applier) |

### Gateway (Envoy Gateway)

| Target | Description |
| -------- | ------------- |
| `make install-envoy-gateway` | Install Envoy Gateway (cluster-wide): the pinned upstream manifest, checksum-verified and patched, plus the shared GatewayClass; a prerequisite of `install-hyperfleet` and `install-gateway` |
| `make uninstall-envoy-gateway` | Uninstall Envoy Gateway, its GatewayClass and its namespace. This deletes the CRDs, and with them every Gateway, route and policy, so uninstall the gateway release first |

### Gateway Authentication (Authorino)

| Target | Description |
| -------- | ------------- |
| `make install-authorino-operator` | Install the pinned Kuadrant Authorino operator (cluster-wide; prerequisite for gateway ext_authz) |
| `make uninstall-authorino-operator` | Uninstall the Authorino operator |
| `make switch-tenant-model` | Switch the active tenant model (`TENANT_MODEL=onprem\|oracle`); re-applies the gateway AuthConfig and API together |
| `make rotate-wristband-key` | Rotate the API gateway wristband signing key; `REVOKE=true` drops the old key without the overlap wait |
| `make mint-human-token` | Mint a test-only JWT from the mock issuer |
| `make mint-machine-token` | Mint a short-lived ServiceAccount JWT for gateway authentication (the gateway validates it through TokenReview) |
| `make check-human-token` | Verify human JWT tenant propagation, audience enforcement, and missing-claim denial |
| `make check-gateway-e2e` | Run the full kind gateway identity, lifecycle, tenant-isolation, shard-isolation, and NetworkPolicy suite |
| `make check-wristband-rotation` | Rotate and then revoke the wristband signing key while checking that requests keep working |

`make install-hyperfleet` installs the Authorino operator automatically before
deploying, so `install-authorino-operator` only needs to be run explicitly for a
standalone/one-off install.

### Terraform

| Target | Description |
| -------- | ------------- |
| `make install-terraform` | `terraform init` + `apply`; writes generated values |
| `make plan-terraform` | `terraform plan` (no apply) |
| `make validate-terraform` | `terraform init -backend=false` + fmt check + validate |
| `make get-credentials` | Configure kubectl from terraform output |
| `make destroy-terraform` | Destroy Terraform-managed infrastructure |

### Tracing

Set `TRACING_ENABLED=true` and `OBSERVABILITY_ENABLED=true`.

| Target | Description |
| -------- | ------------- |
| `make install-tracing` | Install Tempo + OpenTelemetry Collector tracing backend |
| `make uninstall-tracing` | Uninstall Tempo + OpenTelemetry Collector |

### kind

| Target | Description |
| -------- | ------------- |
| `make create-kind-cluster` | Create kind cluster or export kubeconfig if it exists |
| `make delete-kind-cluster` | Delete the kind cluster |
| `make kind-build-images` | Build and load the API, Sentinel, adapter and applier images into kind |
| `make local-up-kind` | Full local kind setup, including the [desire delivery](#desire-delivery) stack |
| `make local-down-kind` | Tear down kind stack and delete cluster |
| `make health-check-desire-delivery` | Wait for Redis and the applier |

### Generated values

| Target | Description |
|--------|-------------|
| `make generate-rabbitmq-values` | Generate RabbitMQ broker Helm values (`HELMFILE_ENV=kind` only) |
| `make clean-generated` | Remove all generated value directories |

### Namespace Cleaner

`make install-cleaner` first provisions the shared `hyperfleet-critical`
PriorityClass, then installs the hourly namespace-cleaner CronJob. The cleaner
uses `Replace` concurrency so stale active Jobs do not block later schedules;
missed schedules are limited to 300 seconds. These scheduling bounds are
configurable in the chart values.

Each run applies two rules:

- **Namespaces** (always on): delete each Active namespace that carries a label
  key in `CLEANER_LABEL_SELECTOR` and is older than `CLEANER_AGE_MINUTES`.
- **Orphans of E2E runs** (off unless `CLEANER_ORPHANS_ENABLED=true`): an E2E
  run namespace is `e2e-<19 digits>` or `rc-e2e-<19 digits>`. When that
  namespace no longer exists, delete the Pub/Sub subscriptions and topics in
  `CLEANER_PUBSUB_PROJECT` whose name starts with `<run namespace>-`, then the
  ClusterRoleBindings and ClusterRoles labelled
  `app.kubernetes.io/managed-by=Helm` whose `meta.helm.sh/release-namespace`
  annotation is that namespace. This covers adapter and applier RBAC whose
  Helm release record is gone.

The orphan rule lists these resources before the namespaces, and a Terminating
namespace counts as present, so a live run keeps its resources. Pub/Sub and
RBAC are checked separately: Pub/Sub is skipped when the cluster is not
`CLEANER_OWNER_CLUSTER`, the token request fails or a Pub/Sub list fails; RBAC
is skipped when an RBAC list fails. Both are skipped when the namespace list
fails or is empty. A skipped kind logs `[ERROR] ... orphan cleanup skipped`
and fails the job, after the namespace rule has run. A failed delete
is logged as `[WARN]` and the others continue, like a failed namespace delete,
and does not fail the job; a 404 counts as deleted. A run whose namespace list
succeeds logs one `Orphan cleanup summary` line with `found`, `kept`, `deleted`
and `failed`.
`CLEANER_DRY_RUN=true` logs what both rules would delete without deleting
anything.

The cleaner calls Pub/Sub with the pod's Workload Identity token from the GKE
metadata server, so its Kubernetes ServiceAccount needs permission to list and
delete topics and subscriptions in `CLEANER_PUBSUB_PROJECT`. All clusters that
run E2E against a project share its Pub/Sub, but only the cluster that runs a
job has its namespace. A project-wide IAM grant does not tell clusters apart,
so before listing Pub/Sub resources the cleaner reads the cluster name from the
GKE metadata server and skips Pub/Sub cleanup unless it is
`CLEANER_OWNER_CLUSTER`. RBAC cleanup uses the local namespace list and runs
independently of this check.
Every `e2e-<19 digits>` name in `hcm-hyperfleet` belongs to
`hyperfleet-dev-prow`; see the [Prow cluster install steps](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/docs/prow-cicd-cluster.md#install-the-namespace-cleaner).

| Target | Description |
|--------|-------------|
| `make install-cleaner` | Install namespace cleaner CronJob (configurable via `CLEANER_*` variables) |
| `make uninstall-cleaner` | Uninstall namespace cleaner CronJob |

### Lifecycle Enforcer

| Target | Description |
| -------- | ------------- |
| `make test-lifecycle-function` | Run unit tests for the lifecycle enforcer Cloud Function |
| `make build-lifecycle-function` | Build the lifecycle enforcer Cloud Function |
| `make lint-lifecycle-function` | Lint the lifecycle enforcer Cloud Function |
| `make add-ttl-labels` | Add TTL labels to existing GKE clusters (`DRY_RUN=true` by default) |

### Validation / CI

| Target | Description |
| -------- | ------------- |
| `make ci-dry-run` | `ci-validate` + `test-terraform-network-policy` + `validate-network-policies` + `validate-namespace-cleaner` + `test-namespace-cleaner` + `validate-desire-delivery` + `validate-fixture-entities` |
| `make test-namespace-cleaner` | Run the namespace-cleaner script against stub `kubectl` and `curl`; check that orphans of deleted E2E run namespaces are deleted and that live, Terminating and non-E2E resources are kept (part of `ci-dry-run`) |
| `make validate-fixture-entities` | Render API, Sentinel and gateway configuration for every environment; check fixture isolation, entity metadata, adapter matching and Sentinel owner references (part of `ci-dry-run`) |
| `make validate-desire-delivery` | Render the remote adapters (the `desire-store-client` releases), Redis and the applier for every environment; fail if a remote adapter transport is not remote with `target_cluster` set to the namespace, or if the Redis NetworkPolicy does not admit the adapter (part of `ci-dry-run`) |
| `make ci-test` | `install-terraform` + `get-credentials` + `install-priority-classes` + `install-desire-delivery` + `health-check-desire-delivery`. Run with `HELMFILE_ENV=e2e-gcp`: the default `gcp` needs Terraform-generated values |
| `make ci-cleanup` | `uninstall-desire-delivery` + `destroy-terraform`. Run with `HELMFILE_ENV=e2e-gcp`, like `ci-test` |
| `make ci-tf-env CI_ID=<id>` | Render `envs/gke/ci-<id>.tfvars` and `.tfbackend` for an ephemeral CI cluster from `ci.tfvars.template` and `ci.tfbackend.template` |
| `make build-ci-tools` | Build the CI tools image (the Prow build root) from `ci/tools/` as `CI_TOOLS_IMAGE` (default `localhost/hyperfleet-infra-tools:dev`), with podman or docker (`CONTAINER_TOOL`) |
| `make test-ci-tools` | `build-ci-tools`, then run `ci-dry-run` and a terraform init without network access in the image as an arbitrary UID. See [ci/tools/README.md](ci/tools/README.md) |
| `make build-wristband-tools` | Build the wristband signing-key lifecycle image (the gateway chart's wristband hooks) from `ci/wristband-tools/` as `WRISTBAND_TOOLS_IMAGE` (default `localhost/hyperfleet-infra-wristband-tools:dev`) for `WRISTBAND_TOOLS_PLATFORM` (default: the host platform), versioned with `WRISTBAND_TOOLS_VERSION` (default: `git describe`), with podman or docker (`CONTAINER_TOOL`) |
| `make test-wristband-tools` | `build-wristband-tools`, then run the hook key operations in the image as UID 1001 with a read-only root filesystem. See [ci/wristband-tools/README.md](ci/wristband-tools/README.md) |
| `make test-wristband-hooks` | Run the four wristband hook scenarios (creation, preservation, rejection, cleanup) of the `hyperfleet-gateway` chart on the kind cluster of the current kubectl context, in `WRISTBAND_HOOK_TEST_NAMESPACE` (default `wristband-hooks-test`; only namespaces labeled by this script are reused). See [ci/wristband-tools/README.md](ci/wristband-tools/README.md) |

## Environment Variables

| Variable | GCP default | kind default | Notes |
| ---------- | ------------ | -------------- | ------- |
| `HELMFILE_ENV` | `gcp` | `kind` | Also `e2e-gcp`, `e2e-kind` |
| `NAMESPACE` | `hyperfleet` | `hyperfleet-local` | e2e envs use `hyperfleet-e2e[-$USER]` |
| `REGISTRY` | `quay.io` | `localhost` | |
| `API_REPOSITORY` | `redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-api` | `hyperfleet-api` | |
| `SENTINEL_REPOSITORY` | `redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-sentinel` | `hyperfleet-sentinel` | |
| `ADAPTER_REPOSITORY` | `redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-adapter` | `hyperfleet-adapter` | |
| `APPLIER_REPOSITORY` | `redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-applier` | `hyperfleet-applier` | |
| `API_IMAGE_TAG` | `dev` | `local` | |
| `SENTINEL_IMAGE_TAG` | `dev` | `local` | |
| `ADAPTER_IMAGE_TAG` | `dev` | `local` | |
| `APPLIER_IMAGE_TAG` | `latest` | `local` | The applier repository publishes no `dev` tag |
| `IMAGE_PULL_POLICY` | `Always` | `IfNotPresent` | |
| `CHART_ORG` | `openshift-hyperfleet` | `openshift-hyperfleet` | GitHub org for helm-git chart repos |
| `API_CHART_REF` | `main` | `main` | Git ref for API chart |
| `SENTINEL_CHART_REF` | `main` | `main` | Git ref for Sentinel chart |
| `ADAPTER_CHART_REF` | `main` | `main` | Git ref for Adapter chart |
| `APPLIER_CHART_REF` | `main` | `main` | Git ref for the applier chart |
| `TF_ENV` | `dev` | N/A | Selects `envs/gke/<TF_ENV>.tfvars` |
| `RABBITMQ_URL` | N/A | `amqp://guest:guest@rabbitmq:5672` | |
| `CLEANER_NAMESPACE` | `$(NAMESPACE)` | `$(NAMESPACE)` | Namespace to install the cleaner into |
| `CLEANER_SCHEDULE` | `0 * * * *` | `0 * * * *` | Cron schedule for the cleaner job |
| `CLEANER_LABEL_SELECTOR` | `hyperfleet.io/cluster-id hyperfleet.io/test-run e2e.hyperfleet.io/run-id` | `hyperfleet.io/cluster-id hyperfleet.io/test-run e2e.hyperfleet.io/run-id` | Space-separated label selectors to identify orphan namespaces; a namespace matching any of them is eligible |
| `CLEANER_AGE_MINUTES` | `120` | `120` | Minimum age (minutes) before a namespace is eligible for cleanup |
| `CLEANER_DRY_RUN` | `false` | `false` | Log what the cleaner would delete without deleting anything |
| `CLEANER_ORPHANS_ENABLED` | `false` | `false` | Delete the Pub/Sub resources and Helm-managed cluster RBAC of deleted E2E run namespaces. Enable only on the cluster that runs the E2E jobs for `CLEANER_PUBSUB_PROJECT` (`hyperfleet-dev-prow`) |
| `CLEANER_PUBSUB_PROJECT` | (empty) | (empty) | GCP project of the E2E Pub/Sub resources; required when `CLEANER_ORPHANS_ENABLED=true` |
| `CLEANER_OWNER_CLUSTER` | (empty) | (empty) | GKE cluster that runs the E2E jobs for `CLEANER_PUBSUB_PROJECT`; required when `CLEANER_ORPHANS_ENABLED=true`. On another cluster, Pub/Sub cleanup is skipped and the job fails; local RBAC cleanup still runs |
| `OBSERVABILITY_ENABLED` | `false` | `false` | Set to `true` to deploy kube-prometheus-stack (Prometheus + Grafana) and enable ServiceMonitors |
| `TRACING_ENABLED` | `false` | `false` | Set to `true` to deploy Tempo + OpenTelemetry Collector and enable OTLP tracing (requires `OBSERVABILITY_ENABLED=true`) |
| `MONITORING_NAMESPACE` | `monitoring` | `monitoring` | Namespace for the observability helmfile releases |
| `TENANT_ISOLATION_ENABLED` | `false` | `false` | Enforce API data isolation from the tenant claims in the gateway wristband |

### Authentication

There is one authentication model. Authorino, behind the gateway, validates the caller and
mints a wristband; the API validates only that wristband. The earlier `AUTH_MODE` choices
(`NONE`, `EDGE`, `API`) no longer exist.

| Caller | Credential sent to the gateway |
| ------ | ------------------------------ |
| Machine (Sentinels, adapters) | `ServiceAccount <projected JWT>` |
| Human | `Bearer <OIDC JWT>` from the configured issuer |

All JWTs use the `hyperfleet-api` audience and the `sub` identity claim. A human issuer is
required: an external `https://` URL (`OIDC_ISSUER_URL`), or the development-only mock
issuer (`OIDC_ISSUER_MODE=mock`).

### Gateway (Envoy Gateway)

The API entry point is an Envoy fleet managed by [Envoy Gateway](https://gateway.envoyproxy.io/)
and configured through Gateway API resources, as decided in ADR-0036. The
`helm/hyperfleet-gateway` chart no longer ships a hand-written Envoy: it renders
these namespaced resources, and Envoy Gateway turns them into the proxy
Deployment and Service.

| Resource | Purpose |
| -------- | ------- |
| `EnvoyProxy` | Proxy infrastructure: replicas, resources, PodDisruptionBudget, the generated Service (type, name, annotations), access log format |
| `Gateway` | The entry point; its listeners come from `gateway.listeners` (plaintext `:8000` for now) |
| `HTTPRoute` | Routes `/` to the API; the retried methods get their own rule |
| `BackendTLSPolicy` | Verifies the API's and Authorino's internal-CA certificates |
| `ClientTrafficPolicy` | Strips client-supplied identity and tenant headers (`headers.stripOverride` adds to a fixed list) before authorization |
| `BackendTrafficPolicy` | Request timeout and retries |
| `NetworkPolicy` | Admits this gateway's Envoy pods to the pods behind the upstream (`upstream.podSelector`) on `upstream.port`; the API's other policies stay in `helm/network-policies` |
| `SecurityPolicy` | Authorino ext_authz on the whole serving listener |
| `EnvoyExtensionPolicy` | Hands the wristband to the upstream: by default it copies it into `Authorization` |

Envoy Gateway is installed once per cluster by `make install-envoy-gateway`, like
cert-manager and the Authorino operator: the pinned upstream `install.yaml`,
checksum-verified, applied with `kubectl`. There is no Helm release, so parallel jobs
on a shared cluster cannot lock each other out. `scripts/patch-envoy-gateway.sh`
changes three things in it: the controller runs in `GatewayNamespace` mode, so each
Gateway's Envoy runs in its own namespace next to Authorino and the API; Lua
`EnvoyExtensionPolicy` support is enabled, which the wristband hand-off needs
(without it Envoy Gateway rejects the policy and answers every request on the Gateway
with a 500); and the topology-injector webhook covers all namespaces. The
cluster-wide RBAC that mode needs is `manifests/envoy-gateway-rbac.yaml`.

The one GatewayClass, `hyperfleet`, is `manifests/envoy-gateway-gatewayclass.yaml`,
applied by the same target. It is cluster-scoped and identical for every release, so
the chart does not render it: the Gateway names it with the `gatewayClassName` value.
When you bump `ENVOY_GATEWAY_VERSION`, update `ENVOY_GATEWAY_MANIFEST_SHA256`, then
check by hand that `scripts/patch-envoy-gateway.sh` still applies (it fails if an
upstream edit no longer matches) and that `manifests/envoy-gateway-rbac.yaml` still
matches the ClusterRole the upstream `gateway-helm` chart renders in this mode.

**Upgrading from the hand-written Envoy chart is a breaking change, and an in-place
upgrade is not supported.** Redeploy the environment instead. The proxy Deployment
and its pod labels change (the gateway release now renders the NetworkPolicy that
admits its Envoy pods to the API, so `make install-gateway` applies it; the older API
policy in `network-policies` keeps its old gateway selector until the next full
install, which is harmless), the generated Service is recreated (on GKE the LoadBalancer IP changes), and Envoy Gateway and the Gateway API
CRDs become cluster-wide prerequisites. A fresh `make install-hyperfleet` creates
everything in the right order.

Names to know:

| Name | Value | Why |
| ---- | ----- | --- |
| Service | `hyperfleet-gateway` | What Sentinel and the adapters call (`http://hyperfleet-gateway:8000`); the generated Service is named after the release |
| Gateway, Envoy Deployment and pods | `hyperfleet-gateway` | The release name; the gateway's own NetworkPolicy admits traffic to the API only from pods labelled `gateway.envoyproxy.io/owning-gateway-name` with this name |

**Values.** Only what differs between environments or gateways is a value; the
rest (timeouts, retry counts, the security contexts, the PodDisruptionBudget, the
ext_authz port) is written into the templates. `values.yaml` has these blocks:

| Block | What it sets |
| ----- | ------------ |
| `gatewayClassName` | The shared GatewayClass the Gateway uses (default `hyperfleet`, created by `make install-envoy-gateway`) |
| `gateway` | The Gateway `listeners` (port, protocol, optional `hostname` and `tls`). Routes and authentication attach to every listener except one marked `authenticated: false`, such as the ACME solver listener |
| `upstream` | The backend this gateway fronts, declared in full by every release (`host`, `port`, `podSelector`): all three are required with no default, so the chart assumes nothing about its upstream. `podSelector` is what the NetworkPolicy selects. Optionally, the Secret with the upstream's serving certificate |
| `envoyProxy` | Replicas, resources, log level, and the Service type and annotations |
| `monitoring.podMonitor.enabled` | Renders a PodMonitor that scrapes the proxy pods; Helmfile sets it when `OBSERVABILITY_ENABLED=true` |
| `headers.stripOverride`, `traffic.retry` | Extra headers removed before authorization (the identity and tenant headers are always removed), and the triggers that are retried (only `GET`, `HEAD`, `PUT` and `DELETE` are, fixed in the route) |
| `authorino` | Everything Authorino: the instance (`name`, `image`, `logLevel`, `hosts`, `authConfigLabelSelectors`, `mockIssuerCASecretName`), `wristbandHookImage` (the image of the signing-key hook Jobs, read in every state), `wristbandHeader` (the header the wristband leaves in: the default `authorization` writes `Bearer <wristband>` over the caller's credential; any other name, such as `x-wristband`, carries the raw token and the caller's `authorization` header is deleted after authorization; see below) and its `policy` |
| `authorino.policy` | The AuthConfig this chart renders: identity providers, machine identity, tenant model and the wristband. The chart assumes nothing about the callers or the upstream: `identityProviders`, `machineIdentity.audience` (the TokenReview audience) and `wristband.audience` (what the upstream validates the wristband against) are required with no defaults, and `machineIdentity.allowedServiceAccounts` (exact names, empty denies every machine caller) must list the machine callers. `policy.wristband.tokenDuration` defaults to 300; `signingKeySecretName` is the key created on a fresh install; `signingKeys` is set only by `make rotate-wristband-key`. Set `policy: null` for a gateway whose AuthConfigs come from elsewhere: no AuthConfig and no signing-key hooks are rendered |

The certificate Secrets are not values: they are named `<upstream.host>-server-cert`,
`<authorino.name>-server-cert` and `<authorino.name>-oidc-server-cert`.

**The wristband header.** The caller's credential always arrives in `Authorization`. By
default the gateway writes the wristband back there as `Bearer <wristband>`, replacing it.
With `authorino.wristbandHeader: x-wristband` the raw token leaves in that header instead,
and the caller's `Authorization` header is deleted, so the upstream receives the wristband in
one header and nothing else. The token comes from Authorino's ext_authz metadata or, for a
custom name, from the header Authorino set itself; a request with neither is denied (403).
A custom name is removed from client requests before authorization, so only Authorino can
have set it. It works for a release whose AuthConfigs come from elsewhere (`policy: null`),
which is how the Desire Store's gateway is configured. `authorization` is rejected in
`headers.stripOverride`, because removing it before authorization would deny every request.

A second gateway, such as the Desire Store's, is a second release of the same
chart with its own `fullnameOverride`, `upstream` (all of `host`, `port` and
`podSelector`), `authorino.name` and `authorino.authConfigLabelSelectors`, and
`authorino.policy: null` when its AuthConfigs come from elsewhere; `make
validate-authorino` renders two releases side by side and fails if their objects
collide.

**How gateways are deployed.** Like adapters and Sentinels: each environment lists
its gateways in `helmfile/environments/<env>/gateway-configs.yaml.gotmpl`, and each
entry names the per-gateway values file (the API gateway's is
`helmfile/values/api-gateway.yaml.gotmpl`; values shared by every gateway are in
`base-gateway.yaml.gotmpl`). The API gateway's release name must stay
`hyperfleet-gateway`: object names and the API's CA secret reference derive from it.

**Which AuthConfigs an Authorino loads.** Each Authorino loads only the AuthConfigs whose
labels match its `authorino.authConfigLabelSelectors`, so two instances in one namespace stay
disjoint. The AuthConfig this chart renders carries `hyperfleet.io/gateway: general`, and the
default selector is `hyperfleet.io/gateway=general`. A release whose AuthConfigs come from
elsewhere, such as the Desire Store's (labelled `hyperfleet.io/desire-store`), sets its own
selector. The selector may use only `key`, `!key`, `key=value` and `key!=value` terms separated
by commas, and it cannot be empty: Authorino treats a selector it cannot parse as matching
everything, so the schema rejects anything else.

### Gateway Authentication (Authorino)

Every API request must have a valid identity before it reaches HyperFleet:
authentication at the gateway is always on and cannot be disabled. Deploying
with a human issuer looks like:

```bash
OIDC_ISSUER_URL=https://issuer.example.com make install-hyperfleet
```

That means:

- human users must send `Authorization: Bearer <token>` from the configured
  OIDC issuer;
- adapters and sentinels authenticate automatically with their Kubernetes
  ServiceAccount tokens as `Authorization: ServiceAccount <token>`;
- unknown ServiceAccounts and unauthenticated requests are denied;
- human identity and tenant information is passed to the API in trusted
  headers; and
- requests are denied if the authentication service is unavailable or does
  not respond in time.

<details>
<summary>Who can access the API?</summary>

```mermaid
flowchart LR
    request["API request"] --> caller{"Who is calling?"}
    caller -->|Human| human{"Valid OIDC token with required tenant claim?"}
    caller -->|Adapter or sentinel| machine{"Valid token from an allowed ServiceAccount?"}
    human -->|Yes| allowed["Request reaches the API"]
    machine -->|Yes| allowed
    human -->|No| denied["Request denied"]
    machine -->|No| denied
```

</details>

#### Before you enable it

Choose an OIDC issuer for human users and confirm that its tokens contain the
claims required by your tenant model. E2E environments default to the namespace-local mock issuer; other environments default to an external issuer:

| `HELMFILE_ENV` | Default `OIDC_ISSUER_MODE` | Mock human issuer used by API/gateway |
| -------------- | -------------------------- | --------------------------- |
| `e2e-gcp`, `e2e-kind` | `mock` | Namespace-local `hyperfleet-mock-oidc` Service |
| `gcp`, `kind` | `external` | Set `OIDC_ISSUER_MODE=mock` explicitly to use the namespace-local `hyperfleet-mock-oidc` Service |

Mock mode is development-only, including in GCP. **Never use it in production.**
It uses the pinned `navikt/mock-oauth2-server` image,
keeps the TLS issuer behind a ClusterIP Service, allows ingress only from Authorino
and the labeled token helper, and uses in-memory signing keys. A mock issuer
restart invalidates previously minted tokens, so mint a fresh token after every
rollout. E2E environments select mock mode by default; set it explicitly for other test deployments.
External mode requires a reachable `https://` `OIDC_ISSUER_URL`. In mock mode,
`OIDC_ISSUER_URL` must be unset because Helmfile derives the mock Service URL.
The mock is installed only in mock mode, and it is ordered before the gateway.
Helmfile retains the disabled release in state so an `install-hyperfleet` mode
change or `uninstall-hyperfleet` removes a previously installed mock issuer.

You do not need to configure credentials manually for adapters and sentinels
deployed by this Helmfile. Their authentication is enabled automatically and
their ServiceAccounts are added to the allow-list. In e2e environments, Helmfile
installs the `hyperfleet-e2e` support chart, which owns `hyperfleet-e2e-runner`.
The E2E process requests a machine token for that ServiceAccount. Temporary
adapters and runner identity are added through e2e-only Helmfile values.

The distinct authorization schemes select mutually exclusive Authorino
authentication methods: `ServiceAccount` invokes Kubernetes TokenReview, while
`Bearer` invokes human OIDC JWT validation. Unknown schemes are denied.

#### Choose a tenant model

`TENANT_MODEL` determines which claims must be present in a human user's token
and which tenant dimensions the API uses to scope resource access:

| Model | Required claim → API key | Optional claim → API key | Use when |
| ----- | ------------------------ | ------------------------ | -------- |
| `onprem` | `org_id` → `org` | `project_id` → `project` | Tenants are organized by organization and optionally project |
| `oracle` | `tenancy_ocid` → `tenancy_ocid` | `compartment_id` → `compartment_id` | Tenants use OCI tenancy and optionally compartment identifiers |

A user whose token is missing the required claim is denied. The optional claim
may be omitted.

> [!IMPORTANT]
> Gateway authentication alone verifies identity and extracts tenant
> information, but does not enable API data isolation. Set
> `TENANT_ISOLATION_ENABLED=true` when tenant separation must be enforced.

#### Deploy

For GCP, enable `use_pubsub` and configure `pubsub_topic_configs` in your
Terraform variables before provisioning. See [Enable Pub/Sub](terraform/README.md#enable-pubsub).
Without them, Terraform does not generate the broker values required by
`HELMFILE_ENV=gcp`. Use an external issuer by default:

```bash
make install-terraform
TENANT_ISOLATION_ENABLED=true \
  OIDC_ISSUER_URL=https://issuer.example.com \
  make install-hyperfleet
```

For a local Kind test deployment, select the development-only mock issuer explicitly:

```bash
HELMFILE_ENV=kind OIDC_ISSUER_MODE=mock \
  TENANT_ISOLATION_ENABLED=true \
  make install-hyperfleet

HELMFILE_ENV=e2e-gcp NAMESPACE=<your-namespace> \
  TENANT_ISOLATION_ENABLED=true \
  make install-hyperfleet
```

To use a real issuer in an e2e environment, override the mode explicitly:

```bash
HELMFILE_ENV=e2e-gcp NAMESPACE=<your-namespace> \
  OIDC_ISSUER_MODE=external \
  TENANT_ISOLATION_ENABLED=true \
  OIDC_ISSUER_URL=https://issuer.example.com \
  TENANT_MODEL=oracle \
  make install-hyperfleet
```

The deployment command ensures that the shared Authorino operator is installed
before deploying HyperFleet. It serves the whole cluster, so do not uninstall
it while another HyperFleet namespace is using gateway authentication.

#### Settings

| Variable | Default | When to set it |
| -------- | ------- | -------------- |
| `TENANT_ISOLATION_ENABLED` | `false` | Scope API data using the tenant claims in the gateway wristband |
| `OIDC_ISSUER_MODE` | `mock` in `e2e-gcp` and `e2e-kind`; `external` otherwise | Set explicitly to override the environment default |
| `OIDC_ISSUER_URL` | unset | HTTPS human issuer; required unless `OIDC_ISSUER_MODE=mock` |
| `TENANT_MODEL` | `onprem` | Set to `oracle` when tokens use OCI tenancy claims |
| `AUTHORINO_HOSTS` | unset | Add comma-separated external gateway hostnames if users access the gateway through them |
| `AUTHORINO_LOG_LEVEL` | `info` | Increase only when diagnosing authentication problems |
| `ENVOY_LOG_LEVEL` | `info` | Increase only when diagnosing gateway problems |
| `ENVOY_GATEWAY_VERSION` | `v1.9.4` | Pinned Envoy Gateway release; update `ENVOY_GATEWAY_MANIFEST_SHA256` with it and recheck the patches and the RBAC file |
| `ENVOY_GATEWAY_MANIFEST` | the release's `install.yaml` | Point at a mirror for disconnected installs |
| `ENVOY_GATEWAY_MANIFEST_SHA256` | pinned | Checksum of the manifest; the install fails if it does not match |

Internal gateway DNS names and `localhost` work without `AUTHORINO_HOSTS`. If
requests through a LoadBalancer or custom DNS name are denied while local
requests work, add the external hostname, for example:

```bash
AUTHORINO_HOSTS=api.example.com,api-alt.example.com \
  OIDC_ISSUER_MODE=external \
  OIDC_ISSUER_URL=https://issuer.example.com \
  make install-hyperfleet
```

#### Change the tenant model

Reapply the deployment with the new model:

```bash
TENANT_ISOLATION_ENABLED=true \
  OIDC_ISSUER_MODE=external \
  OIDC_ISSUER_URL=https://issuer.example.com \
  make switch-tenant-model TENANT_MODEL=oracle
```

After the switch, human tokens must contain the new model's required claim.
All human tokens must also include `hyperfleet-api` in the JWT `aud` claim.

#### Mock human tokens and gateway checks

The mock issuer exposes a documented Make interface for later gateway suites
and for manual checks. The helper prints only the raw JWT to stdout and sends
mode, model, and claim diagnostics to stderr. It never stores the token in a
Kubernetes Secret, ConfigMap, annotation, or file. Tenant values are sent to a
short-lived pinned curl pod through stdin rather than pod command arguments.
Stdout is therefore a credential-bearing interface: callers must capture it
directly and must not redirect it to logs or other persistent output.

Mint an on-prem token with only its required claim:

```bash
token=$(HELMFILE_ENV=kind OIDC_ISSUER_MODE=mock \
  TENANT_MODEL=onprem TOKEN_TENANT=org-acme \
  make mint-human-token)
```

Mint one with the optional project claim:

```bash
HELMFILE_ENV=kind OIDC_ISSUER_MODE=mock \
  TENANT_MODEL=onprem TOKEN_TENANT=org-acme TOKEN_SUBTENANT=project-blue \
  make mint-human-token
```

Mint Oracle and deliberately invalid tokens with the same interface:

```bash
HELMFILE_ENV=kind OIDC_ISSUER_MODE=mock \
  TENANT_MODEL=oracle TOKEN_TENANT=ocid1.tenancy.oc1..example \
  TOKEN_SUBTENANT=ocid1.compartment.oc1..example make mint-human-token

HELMFILE_ENV=kind OIDC_ISSUER_MODE=mock \
  TENANT_MODEL=onprem TOKEN_MISSING_REQUIRED=true \
  TOKEN_TENANT=org-acme make mint-human-token

HELMFILE_ENV=kind OIDC_ISSUER_MODE=mock \
  TENANT_MODEL=oracle TOKEN_MISSING_REQUIRED=true \
  TOKEN_TENANT=ocid1.tenancy.oc1..example make mint-human-token
```

Run the narrow propagation check after installing with tenant isolation. It
creates and cleans up one temporary Cluster, verifies the selected tenancy
values in the API response, and confirms that a token with the wrong audience
receives HTTP 401 and a token without the required claim receives HTTP 403. For `kind` and `e2e-kind`, both
token helpers verify that the active kubectl context is a kind context before
they mutate the cluster:

```bash
HELMFILE_ENV=kind OIDC_ISSUER_MODE=mock \
  TENANT_ISOLATION_ENABLED=true \
  TENANT_MODEL=onprem TOKEN_TENANT=org-acme TOKEN_SUBTENANT=project-blue \
  make check-human-token
```

The helper checks the fixed explicit headers (`x-tenant-org` /
`x-tenant-project` or `x-tenant-tenancy-ocid` / `x-tenant-compartment`). It does
not create a JSON tenancy-context header or support arbitrary future tenant
dimensions. Those require a coordinated gateway AuthConfig and API change.

Envoy replaces the validated original credential with a short-lived Authorino
wristband, and the API validates that wristband against Authorino's OIDC endpoint
using the namespace-local gateway CA. The API never accepts the original human or
ServiceAccount credentials.

#### Rotate the wristband signing key

Run the target with the same variables you deployed with, because it
redeploys the gateway release:

```bash
HELMFILE_ENV=kind make rotate-wristband-key              # overlap, about 6 minutes
HELMFILE_ENV=kind make rotate-wristband-key REVOKE=true  # compromised key
```

The target rotates the API gateway's key (release `hyperfleet-gateway`), the
only gateway whose wristband keys this chart manages. The AuthConfig, the
Authorino instance and the signing-key Secrets are resolved by that release's
labels, and the redeploy is scoped to it, so a second gateway in the namespace
is never touched.

Authorino signs with the first key in the AuthConfig and publishes every key
in its JWKS. The JWT key ID is the Secret name, so every rotation creates a new
Secret, `hyperfleet-wristband-signing-key-<UTC timestamp>`, in-cluster through
the gateway chart's provisioner hook.

- Without `REVOKE`, the AuthConfig goes from `[old]` to `[new, old]`. The
  target waits until Authorino publishes both keys, then the wristband
  `tokenDuration` plus the API's 30-second leeway (330 seconds), then drops the
  old key. No request fails: the API fetches the JWKS again when it sees an
  unknown key ID.
- With `REVOKE=true`, the AuthConfig goes from `[old]` to `[new]` at once.
  Requests in flight with an old wristband can fail. The API stops trusting the
  old key at its next JWKS refresh: the first request with the new key, or at
  most 5 minutes later.

The AuthConfig is the state: it lists the trusted keys and its first entry
signs. The target passes the new key list to the gateway chart, and a plain
`make install-gateway` keeps whatever the AuthConfig already lists. The chart's
provisioner hook creates the new Secret, labeled
`hyperfleet.io/wristband-signing-key=<release>`, before the AuthConfig changes.
After an upgrade, a sweep hook deletes the Secrets labeled for this release that
the AuthConfig no longer lists, so it never touches another release's keys.

If the target stops early, run it again. A rerun issues another key and ends
with only that key. After a stop with `REVOKE=true`, requests with old
wristbands can fail until a run completes. Any labeled Secret that a stopped
run left behind is deleted by the next gateway deploy.

The AuthConfig decides trust, so the right to edit it, like cluster-admin, is an
authentication-boundary privilege. The label only scopes deletion: the sweep
deletes any labeled Secret the AuthConfig does not list.

`helm rollback` of the gateway release to a revision before a completed
rotation is not supported. The restored AuthConfig names a deleted Secret, and
the gateway denies every request. Rolling back to a previous key is not supported: a completed
rotation deletes the old Secret.

#### Machine tokens and TokenReview smoke checks

`make mint-machine-token` requests a short-lived TokenRequest API JWT for a
ServiceAccount. It defaults to `adapter1-hyperfleet-adapter` for `kind` and
`gcp`, and `cl-desire-hyperfleet-adapter` for `e2e-kind` and `e2e-gcp`. It
uses the `hyperfleet-api` audience and a 10-minute duration—the Kubernetes API
server minimum—and prints only the JWT to stdout. Override
`MACHINE_SERVICE_ACCOUNT`, `MACHINE_TOKEN_AUDIENCE`, or
`MACHINE_TOKEN_DURATION` as needed.

```bash
token=$(HELMFILE_ENV=kind \
  make mint-machine-token)

curl -i -H "Authorization: ServiceAccount $token" \
  http://localhost:8000/api/hyperfleet/v1/clusters
```

The `ServiceAccount` authorization scheme is intentional: it selects
Authorino's Kubernetes TokenReview path. To verify a rejection case, request a
token for a ServiceAccount not included in the Helmfile-derived allow-list.

#### Gateway end-to-end suite

`make check-gateway-e2e` is the local regression suite for the gateway
boundary. It needs a kind deployment with mock OIDC and tenant isolation:

```bash
HELMFILE_ENV=kind OIDC_ISSUER_MODE=mock TENANT_ISOLATION_ENABLED=true \
  make local-up-kind

make check-gateway-e2e
```

The target defaults to those three values, and values you pass still win. The
suite runs every check on the on-prem tenant model, switches to Oracle, runs
them again, and restores on-prem even when a check fails. Do not redeploy the
gateway or API while it runs. It prints a `PASS` line per check, and on failure
the failing check with a suggested fix.

`make check-human-token` runs only the human token checks.
`GATEWAY_E2E_TIMEOUT` (default 300 seconds) bounds each wait.

`make check-wristband-rotation` needs the same deployment. It is not part of
`check-gateway-e2e` because it takes about 8 minutes. It rotates the key while
it sends one request after another and requires that none fails. It then
redeploys the gateway and checks that the rotated key stays, and finally
revokes the key.

### Desire delivery

Every environment runs the delivery chain API → Sentinel → remote adapter →
desire store → applier. In the run namespace Helmfile deploys:

- `redis`: the desire store (`helm/redis`, Service `redis:6379`, no auth, no
  persistence). The `redis-ingress` NetworkPolicy admits only the remote
  adapter and applier pods.
- `hyperfleet-applier`: the applier chart from the `hyperfleet-applier` repository,
  named `hyperfleet-applier-<namespace>` (shortened with a hash suffix when that
  exceeds 63 characters). It serves the store partition named
  after the namespace and may manage only Namespaces and ConfigMaps.
- The remote adapter: `cl-desire` in `e2e-kind` and `e2e-gcp`, `adapter2` in
  `kind` and `gcp`. It runs the task in `helmfile/configs/base/adapters/remote/`,
  routed through a remote transport to the same partition
  (`helmfile/values/remote-adapter.yaml.gotmpl`). The API
  requires it for clusters like any other adapter.

Kind image builds include the applier, so `PROJECTS_DIR` must contain
`hyperfleet-applier` (or set `BUILD_IMAGES=false`). `make local-up-kind` and
`make local-up-gcp` both end with `make health-check-desire-delivery`.

`make install-desire-delivery` and `make uninstall-desire-delivery` manage only
the `redis` and `hyperfleet-applier` releases, for example in a cluster where
the rest of HyperFleet is managed separately:

```bash
HELMFILE_ENV=e2e-gcp NAMESPACE=<namespace> make install-desire-delivery health-check-desire-delivery
```

### E2E specific variables

Variables only needed for e2e environments (HELMFILE_ENV=e2e-gcp/e2e-kind).

| Variable | Default | Description |
|----------|---------|-------------|
| `RUN_ID` | `NAMESPACE` | The runId for the e2e environment |

### Kind specific variables

Variables only needed for kind environments (HELMFILE_ENV=kind/e2e-kind).

| Variable | Default | Description |
| ---------- | --------- | ------------- |
| `PROJECTS_DIR` | `~/openshift-hyperfleet` | Parent dir for sibling repos (image builds) |
| `BUILD_IMAGES` | true | Set to false to skip image builds |
| `KIND_CLUSTER_NAME` | `kind` | The name of the kind cluster |

## Repository Structure

```
hyperfleet-infra/
├── Makefile                          # Entry point: run 'make help'
├── env.gcp, env.kind                 # Variable defaults (GCP: Pub/Sub, LoadBalancer; kind: RabbitMQ, ClusterIP)
├── helmfile/                         # Helmfile state: per-env adapter and sentinel lists, adapter configs, value templates
├── helm/                             # Local charts (gateway, E2E support, Redis, RabbitMQ, mock OIDC, ...)
├── manifests/                        # Plain Kubernetes manifests (priority classes, ...)
├── scripts/                          # Helper scripts, most run through make targets
├── terraform/                        # GKE and shared VPC stacks, OCI CI stack in terraform/oci/ (see terraform/README.md)
├── functions/                        # Go cloud functions
├── ci/tools/                         # Prow build root tools image (see ci/tools/README.md)
├── generated-values-from-terraform/  # Generated, gitignored
└── generated-values-rabbitmq/        # Generated, gitignored
```

The tree lists only the top level, which rarely changes, so it stays accurate.

## Generated Helm Values

Both generated directories are gitignored and must exist before `make install-hyperfleet`.

| Env | How generated | Directory |
| ----- | --------------- | ----------- |
| `gcp` | `make install-terraform` (Terraform `local_file`) | `generated-values-from-terraform/` |
| `kind` | `make generate-rabbitmq-values` (shell script) | `generated-values-rabbitmq/` |
| `e2e-gcp` / `e2e-kind` | Not needed — hardcoded in helmfile | — |

Files written per component:

| File | Component |
| ------ | ----------- |
| `sentinel-clusters.yaml` | Sentinel (cluster events) |
| `sentinel-nodepools.yaml` | Sentinel (nodepool events) |
| `adapter1.yaml` | Adapter 1 |
| `adapter2.yaml` | Adapter 2 |
| `adapter3.yaml` | Adapter 3 |

## Shared Infrastructure (one-time admin setup)

The shared VPC must be deployed once before any developer clusters. This is an admin-only operation:

```bash
cd terraform/shared
terraform init -backend-config=shared.tfbackend
terraform apply
```

See [terraform/shared/README.md](terraform/shared/README.md) for details.

## Lifecycle Enforcer

A Cloud Function (Go) that enforces the [GCP Developer Cluster Lifecycle Policy](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/docs/gcp-developer-cluster-lifecycle.md) — idle shutdown (>12h), TTL expiration, and missing owner enforcement. Runs hourly via Cloud Scheduler, deployed via Terraform (`enable_lifecycle_enforcer = true`).

See [functions/lifecycle-enforcer/README.md](functions/lifecycle-enforcer/README.md) for architecture, deployment, rollout, and configuration details.

## Related Repositories

- [hyperfleet-api](https://github.com/openshift-hyperfleet/hyperfleet-api) — API server
- [hyperfleet-sentinel](https://github.com/openshift-hyperfleet/hyperfleet-sentinel) — Sentinel
- [hyperfleet-adapter](https://github.com/openshift-hyperfleet/hyperfleet-adapter) — Adapter Framework
- [architecture](https://github.com/openshift-hyperfleet/architecture) — System architecture and standards

## License

Apache License 2.0
