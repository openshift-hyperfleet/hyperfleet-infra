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

- `terraform 1.13.1` (pinned via `.tool-versions`; use [asdf](https://asdf-vm.com/))
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
| `make install-api` | Install HyperFleet API only |
| `make install-sentinels` | Install Sentinels only |
| `make install-adapters` | Install Adapters only |
| `make uninstall-hyperfleet` | Uninstall all HyperFleet components |
| `make uninstall-api` | Uninstall API only |
| `make uninstall-sentinels` | Uninstall Sentinels only |
| `make uninstall-adapters` | Uninstall Adapters only |

### Gateway Authentication (Authorino)

| Target | Description |
| -------- | ------------- |
| `make install-authorino-operator` | Install the pinned Kuadrant Authorino operator (cluster-wide; prerequisite for gateway ext_authz) |
| `make uninstall-authorino-operator` | Uninstall the Authorino operator |
| `make switch-tenant-model` | Switch the active tenant model (`TENANT_MODEL=onprem\|oracle`); re-applies the gateway AuthConfig and API together |
| `make mint-human-token` | Mint a test-only JWT from the mock issuer |
| `make mint-machine-token` | Mint a short-lived ServiceAccount JWT for the gateway TokenReview flow |
| `make check-human-token` | Verify human JWT tenant propagation, audience enforcement, and missing-claim denial |

When `AUTH_MODE=EDGE` or `AUTH_MODE=EDGE+API`, `make install-hyperfleet` installs the Authorino
operator automatically before deploying, so `install-authorino-operator` only
needs to be run explicitly for a standalone/one-off install.

### Terraform

| Target | Description |
| -------- | ------------- |
| `make install-terraform` | `terraform init` + `apply`; writes generated values |
| `make plan-terraform` | `terraform plan` (no apply) |
| `make validate-terraform` | `terraform init -backend=false` + fmt check + validate |
| `make get-credentials` | Configure kubectl from terraform output |
| `make destroy-terraform` | Destroy Terraform-managed infrastructure |

### Maestro

| Target | Description |
| -------- | ------------- |
| `make install-maestro` | Install Maestro server + agent (runs `helm dependency update` first) |
| `make create-maestro-consumer` | Create a Maestro consumer (requires Maestro running) |
| `make install-maestro-all` | `install-maestro` + `create-maestro-consumer` |
| `make uninstall-maestro` | Uninstall Maestro |

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
| `make kind-build-images` | Build and load component images into kind |
| `make local-up-kind` | Full local kind setup |
| `make local-down-kind` | Tear down kind stack and delete cluster |

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
| `make ci-dry-run` | `ci-validate` + `validate maestro` + `validate namespace cleaner` + other chart/config checks |
| `make ci-test` | `install terraform` + `get-credentials` + `install-maestro` + `create-maestro-consumer` + `health-check-maestro` |
| `make ci-cleanup` | `uninstall-maestro` + `destroy-terraform` |
| `make ci-tf-env CI_ID=<id>` | Render `envs/gke/ci-<id>.tfvars` and `.tfbackend` for an ephemeral CI cluster from `ci.tfvars.template` and `ci.tfbackend.template` |

## Environment Variables

| Variable | GCP default | kind default | Notes |
| ---------- | ------------ | -------------- | ------- |
| `HELMFILE_ENV` | `gcp` | `kind` | Also `e2e-gcp`, `e2e-kind` |
| `NAMESPACE` | `hyperfleet` | `hyperfleet-local` | e2e envs use `hyperfleet-e2e[-$USER]` |
| `MAESTRO_NAMESPACE` | `maestro` | `maestro` | |
| `REGISTRY` | `quay.io` | `localhost` | |
| `API_REPOSITORY` | `redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-api` | `hyperfleet-api` | |
| `SENTINEL_REPOSITORY` | `redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-sentinel` | `hyperfleet-sentinel` | |
| `ADAPTER_REPOSITORY` | `redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-adapter` | `hyperfleet-adapter` | |
| `API_IMAGE_TAG` | `dev` | `local` | |
| `SENTINEL_IMAGE_TAG` | `dev` | `local` | |
| `ADAPTER_IMAGE_TAG` | `dev` | `local` | |
| `IMAGE_PULL_POLICY` | `Always` | `IfNotPresent` | |
| `CHART_ORG` | `openshift-hyperfleet` | `openshift-hyperfleet` | GitHub org for helm-git chart repos |
| `API_CHART_REF` | `main` | `main` | Git ref for API chart |
| `SENTINEL_CHART_REF` | `main` | `main` | Git ref for Sentinel chart |
| `ADAPTER_CHART_REF` | `main` | `main` | Git ref for Adapter chart |
| `TF_ENV` | `dev` | N/A | Selects `envs/gke/<TF_ENV>.tfvars` |
| `RABBITMQ_URL` | N/A | `amqp://guest:guest@rabbitmq:5672` | |
| `MAESTRO_CONSUMER` | `cluster1` | `cluster1` | |
| `CLEANER_NAMESPACE` | `$(NAMESPACE)` | `$(NAMESPACE)` | Namespace to install the cleaner into |
| `CLEANER_SCHEDULE` | `0 * * * *` | `0 * * * *` | Cron schedule for the cleaner job |
| `CLEANER_LABEL_SELECTOR` | `hyperfleet.io/cluster-id` | `hyperfleet.io/cluster-id` | Label selector to identify orphan namespaces |
| `CLEANER_AGE_MINUTES` | `120` | `120` | Minimum age (minutes) before a namespace is eligible for cleanup |
| `CLEANER_MAESTRO_URL` | `http://maestro.$(MAESTRO_NAMESPACE).svc.cluster.local:8000` | `http://maestro.$(MAESTRO_NAMESPACE).svc.cluster.local:8000` | Maestro API URL used by the cleaner |
| `OBSERVABILITY_ENABLED` | `false` | `false` | Set to `true` to deploy kube-prometheus-stack (Prometheus + Grafana) and enable ServiceMonitors |
| `TRACING_ENABLED` | `false` | `false` | Set to `true` to deploy Tempo + OpenTelemetry Collector and enable OTLP tracing (requires `OBSERVABILITY_ENABLED=true`) |
| `MONITORING_NAMESPACE` | `monitoring` | `monitoring` | Namespace for the observability helmfile releases |
| `TENANT_ISOLATION_ENABLED` | `false` | `false` | Enforce API data isolation from trusted gateway tenant headers; requires `AUTH_MODE=EDGE` or `EDGE+API` |

### Authentication modes

`AUTH_MODE` is the only authentication-placement control:

| Mode | Gateway | API | Machine credential | Human credential |
| ---- | ------- | --- | ------------------ | ---------------- |
| `NONE` | No authentication | No JWT validation | None | None |
| `EDGE` | Authorino validates callers | Trusts gateway headers | `ServiceAccount <projected JWT>` | `Bearer <OIDC JWT>` |
| `API` | No authentication | Directly validates JWTs | `Bearer <projected JWT>` | `Bearer <OIDC JWT>` |
| `EDGE+API` | Authorino validates callers and mints a wristband | Validates only the gateway wristband | `ServiceAccount <projected JWT>` to the gateway | `Bearer <OIDC JWT>` to the gateway |

`API` mode configures the Kubernetes issuer for projected ServiceAccount tokens
and supports one optional direct human OIDC provider. Set `OIDC_ISSUER_URL` and
`OIDC_JWKS_URL` to enable that human provider. All supported JWTs use the
`hyperfleet-api` audience and `sub` identity claim.

### Gateway Authentication (Authorino)

Enable gateway authentication when you want every API request to have a valid
identity before it reaches HyperFleet. Once an OIDC issuer is configured, turn
it on with:

```bash
AUTH_MODE=EDGE make install-hyperfleet
```

With this setting enabled:

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
claims required by your tenant model. The issuer mode is explicit and is
reported by the install validation step:

| `HELMFILE_ENV` | Default `OIDC_ISSUER_MODE` | Issuer used by the gateway |
| -------------- | -------------------------- | --------------------------- |
| `kind` / `e2e-kind` | `mock` | Namespace-local `hyperfleet-mock-oidc` Service |
| `e2e-gcp` | `mock` | Namespace-local `hyperfleet-mock-oidc` Service |
| `gcp` | `external` | Terraform-generated or CLI-supplied HTTPS issuer |

Mock mode is test-only. It uses the pinned `navikt/mock-oauth2-server` image,
keeps the issuer behind a ClusterIP Service, allows ingress only from Authorino
and the labeled token helper, and uses in-memory signing keys. A mock issuer
restart invalidates previously minted tokens, so mint a fresh token after every
rollout. Set `OIDC_ISSUER_MODE=external` to use a real issuer in any environment.
External mode requires a reachable `https://` `OIDC_ISSUER_URL` in `EDGE` or
`EDGE+API` mode when human authentication is enabled. In mock mode,
`OIDC_ISSUER_URL` must be unset because Helmfile derives the mock Service URL.
Terraform-generated issuer values are loaded only for the
regular `gcp` environment. Mock mode is allowed only in `kind`, `e2e-kind`, and
`e2e-gcp`; use `e2e-gcp` for a GCP-backed test with the mock issuer.

For the regular `gcp` environment, `make install-terraform` generates the
cluster's external issuer configuration automatically. The mock is installed
only when gateway auth uses mock mode, and it is ordered before the gateway.
Helmfile retains the disabled release in state so an `install-hyperfleet` mode
change or `uninstall-hyperfleet` removes a previously installed mock issuer.

You do not need to configure credentials manually for adapters and sentinels
deployed by this Helmfile. Their authentication is enabled automatically and
their ServiceAccounts are added to the allow-list. The e2e environments also
include the ServiceAccounts created by the e2e test suite.

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
> information, but does not enable API data isolation. Set both
> `AUTH_MODE=EDGE` (or `EDGE+API`) and `TENANT_ISOLATION_ENABLED=true` when tenant
> separation must be enforced.

#### Deploy

For GCP, first provision Terraform so the issuer URL is generated, then enable
gateway authentication:

```bash
make install-terraform
AUTH_MODE=EDGE TENANT_ISOLATION_ENABLED=true make install-hyperfleet
```

For kind and CI-shaped environments, the mock issuer is enabled without an
issuer URL:

```bash
HELMFILE_ENV=kind AUTH_MODE=EDGE TENANT_ISOLATION_ENABLED=true \
  make install-hyperfleet

HELMFILE_ENV=e2e-gcp NAMESPACE=<your-namespace> \
  AUTH_MODE=EDGE TENANT_ISOLATION_ENABLED=true \
  make install-hyperfleet
```

To use a real issuer in an e2e environment, override the mode explicitly:

```bash
HELMFILE_ENV=e2e-gcp NAMESPACE=<your-namespace> \
  OIDC_ISSUER_MODE=external \
  AUTH_MODE=EDGE TENANT_ISOLATION_ENABLED=true \
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
| `AUTH_MODE` | `NONE` | One of `NONE`, `EDGE`, `API`, or `EDGE+API` |
| `TENANT_ISOLATION_ENABLED` | `false` | Scope API data using trusted gateway headers; requires `AUTH_MODE=EDGE` or `EDGE+API` |
| `OIDC_ISSUER_MODE` | `mock` except regular `gcp` (`external`) | Select `mock` or `external` for edge modes |
| `OIDC_ISSUER_URL` | unset | HTTPS human issuer; API mode also requires `OIDC_JWKS_URL` |
| `OIDC_JWKS_URL` | unset | Explicit human-provider JWKS URL for API mode |
| `TENANT_MODEL` | `onprem` | Set to `oracle` when tokens use OCI tenancy claims |
| `AUTHORINO_HOSTS` | unset | Add comma-separated external gateway hostnames if users access the gateway through them |
| `AUTHORINO_LOG_LEVEL` | `info` | Increase only when diagnosing authentication problems |
| `ENVOY_LOG_LEVEL` | `info` | Increase only when diagnosing gateway problems |

Internal gateway DNS names and `localhost` work without `AUTHORINO_HOSTS`. If
requests through a LoadBalancer or custom DNS name are denied while local
requests work, add the external hostname, for example:

```bash
AUTHORINO_HOSTS=api.example.com,api-alt.example.com \
  AUTH_MODE=EDGE \
  OIDC_ISSUER_URL=https://issuer.example.com \
  make install-hyperfleet
```

#### Change the tenant model

Reapply the deployment with the new model:

```bash
AUTH_MODE=EDGE TENANT_ISOLATION_ENABLED=true \
  OIDC_ISSUER_URL=https://issuer.example.com \
  make switch-tenant-model TENANT_MODEL=oracle
```

After the switch, human tokens must contain the new model's required claim.
All human tokens must also include `hyperfleet-api` in the JWT `aud` claim.

#### Mock human tokens and smoke check

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
values in the API response, and confirms that tokens with the wrong audience or
without the required claim receive HTTP 403. For `kind` and `e2e-kind`, both
token helpers verify that the active kubectl context is a kind context before
they mutate the cluster:

```bash
HELMFILE_ENV=kind OIDC_ISSUER_MODE=mock \
  AUTH_MODE=EDGE TENANT_ISOLATION_ENABLED=true \
  TENANT_MODEL=onprem TOKEN_TENANT=org-acme TOKEN_SUBTENANT=project-blue \
  make check-human-token
```

The helper checks the fixed explicit headers (`x-tenant-org` /
`x-tenant-project` or `x-tenant-tenancy-ocid` / `x-tenant-compartment`). It does
not create a JSON tenancy-context header or support arbitrary future tenant
dimensions. Those require a coordinated gateway AuthConfig and API change.

`EDGE+API` is the defense-in-depth mode: Envoy replaces the validated original
credential with a short-lived Authorino wristband, and the API validates that
wristband against Authorino's OIDC endpoint using the namespace-local gateway
CA. The API never accepts the original human or ServiceAccount credentials in
this mode.

#### Machine tokens and TokenReview smoke checks

`make mint-machine-token` requests a short-lived TokenRequest API JWT for a
ServiceAccount. It defaults to `adapter1-hyperfleet-adapter` for `kind` and
`gcp`, and `cl-maestro-hyperfleet-adapter` for `e2e-kind` and `e2e-gcp`. It
uses the `hyperfleet-api` audience and a 10-minute duration—the Kubernetes API
server minimum—and prints only the JWT to stdout. Override
`MACHINE_SERVICE_ACCOUNT`, `MACHINE_TOKEN_AUDIENCE`, or
`MACHINE_TOKEN_DURATION` as needed.

```bash
token=$(HELMFILE_ENV=kind AUTH_MODE=EDGE \
  make mint-machine-token)

curl -i -H "Authorization: ServiceAccount $token" \
  http://localhost:8000/api/hyperfleet/v1/clusters
```

The `ServiceAccount` authorization scheme is intentional: it selects
Authorino's Kubernetes TokenReview path. To verify a rejection case, request a
token for a ServiceAccount not included in the Helmfile-derived allow-list.

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
├── Makefile                         # Entry point — run 'make help'
├── env.gcp                          # GCP defaults (Google Pub/Sub, LoadBalancer)
├── env.kind                         # kind defaults (RabbitMQ, ClusterIP)
├── helmfile/
│   ├── helmfile.yaml.gotmpl         # Helmfile orchestration
│   ├── environments/                # Per-env configs (gcp, kind, e2e-gcp, e2e-kind)
│   ├── configs/
│   │   ├── base/adapters/           # Adapter configs (adapter1, adapter2, adapter3)
│   │   └── e2e/adapters/            # E2E adapter configs
│   └── values/                      # Helm value templates (.gotmpl)
├── helm/
│   ├── maestro/                     # Maestro umbrella chart (deps via helm-git)
│   └── rabbitmq/                    # Dev-only RabbitMQ (not production-ready)
├── scripts/
│   ├── add-ttl-labels.sh            # Adds TTL labels to existing GKE clusters
│   ├── generate-rabbitmq-values.sh  # Generates RabbitMQ broker config
│   └── kind-build-images.sh         # Builds and loads images into kind
├── functions/
│   └── lifecycle-enforcer/          # Cloud Function: GKE cluster lifecycle enforcement
├── terraform/
│   ├── README.md                    # Detailed Terraform documentation
│   ├── main.tf                      # Root module (GKE cluster, Pub/Sub, firewall, lifecycle)
│   ├── helm-values-files.tf         # Writes generated Helm values via local_file
│   ├── bootstrap/                   # One-time GCP setup scripts (admin only)
│   ├── shared/                      # Shared VPC infrastructure (deploy once)
│   ├── modules/
│   │   ├── cluster/gke/             # GKE cluster module
│   │   ├── lifecycle/               # Lifecycle enforcer (Cloud Function + Scheduler)
│   │   └── pubsub/                  # Google Pub/Sub module
│   └── envs/gke/                    # Per-developer tfvars and tfbackend files, prow config, CI templates
├── generated-values-from-terraform/ # Auto-generated, gitignored
└── generated-values-rabbitmq/       # Auto-generated, gitignored
```

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
