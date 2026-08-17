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

- `helm` + [`helm-diff` plugin](https://github.com/databus23/helm-diff)
- `helmfile`
- `kubectl` with a configured context

```bash
helm plugin install https://github.com/databus23/helm-diff --verify=false
```

**Note**: [`helm-git` plugin](https://github.com/aslafy-z/helm-git) only needed for Maestro external dependency (dev-only). HyperFleet charts consumed via OCI.

### GCP only

- `terraform 1.13.1` (pinned via `.tool-versions`; use [asdf](https://asdf-vm.com/))
- [Google Cloud SDK](https://cloud.google.com/sdk/docs/install) (`gcloud`) + `gke-gcloud-auth-plugin`
- Access to the `hcm-hyperfleet` GCP project

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
| `make ci-dry-run` | `ci-validate` + `validate maestro` |
| `make ci-test` | `install terraform` + `get-credentials` + `install-maestro` + `create-maestro-consumer` + `health-check-maestro` |
| `make ci-cleanup` | `uninstall-maestro` + `destroy-terraform` |

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
| `TF_ENV` | `dev` | N/A | Selects `envs/gke/<TF_ENV>.tfvars` |
| `RABBITMQ_URL` | N/A | `amqp://guest:guest@rabbitmq:5672` | |
| `MAESTRO_CONSUMER` | `cluster1` | `cluster1` | |
| `CLEANER_NAMESPACE` | `$(NAMESPACE)` | `$(NAMESPACE)` | Namespace to install the cleaner into |
| `CLEANER_SCHEDULE` | `0 * * * *` | `0 * * * *` | Cron schedule for the cleaner job |
| `CLEANER_LABEL_SELECTOR` | `hyperfleet.io/cluster-id` | `hyperfleet.io/cluster-id` | Label selector to identify orphan namespaces |
| `CLEANER_AGE_MINUTES` | `180` | `180` | Minimum age (minutes) before a namespace is eligible for cleanup |
| `CLEANER_MAESTRO_URL` | `http://maestro.$(MAESTRO_NAMESPACE).svc.cluster.local:8000` | `http://maestro.$(MAESTRO_NAMESPACE).svc.cluster.local:8000` | Maestro API URL used by the cleaner |
| `OBSERVABILITY_ENABLED` | `false` | `false` | Set to `true` to deploy kube-prometheus-stack (Prometheus + Grafana) and enable ServiceMonitors |
| `TRACING_ENABLED` | `false` | `false` | Set to `true` to deploy Tempo + OpenTelemetry Collector and enable OTLP tracing (requires `OBSERVABILITY_ENABLED=true`) |
| `MONITORING_NAMESPACE` | `monitoring` | `monitoring` | Namespace for the observability helmfile releases |

### JWT Authentication (optional)

| Variable | Default | Description |
| ---------- | --------- | ------------- |
| `JWT_AUTH_ENABLED` | `false` | Set to `true` to enable JWT validation on the API and SA-token auth on sentinel/adapter |
| `OIDC_ISSUER_URL` | *(unset; from Terraform for GCP)* | GCP OIDC issuer. When set, uses GCP OIDC. When absent, uses K8s in-cluster OIDC. |
| `OIDC_JWKS_URL` | *(empty: Helm chart derives `OIDC_ISSUER_URL/jwks` itself if not set)* | Public JWKS endpoint for the above issuer (ignored when using in-cluster OIDC) |

When `JWT_AUTH_ENABLED=true`, the template auto-detects the backend based on `OIDC_ISSUER_URL`:

- **Kind** (no `OIDC_ISSUER_URL`): the API validates tokens from the in-cluster K8s OIDC provider. No extra config needed.
- **GKE** (with `OIDC_ISSUER_URL`): the API validates JWTs from two issuers: the GKE cluster (for sentinel/adapter SA tokens with audience `hyperfleet-api`) and Google accounts (for human callers).

In both cases, **Sentinels** and **Adapters** mount a projected ServiceAccount token with audience `hyperfleet-api` and attach it as a bearer token on every API call.

`OIDC_ISSUER_URL` is cluster-specific. For GCP environments it is populated automatically from `generated-values-from-terraform/oidc.env` after `make install-terraform`. For e2e-gcp (no Terraform), pass it on the CLI.

```bash
# Kind
JWT_AUTH_ENABLED=true HELMFILE_ENV=kind make install-hyperfleet

# GKE (OIDC_ISSUER_URL set automatically by make install-terraform)
JWT_AUTH_ENABLED=true make install-hyperfleet

# e2e-gcp (no Terraform, pass OIDC_ISSUER_URL manually)
HELMFILE_ENV=e2e-gcp NAMESPACE=<your-namespace> \
  JWT_AUTH_ENABLED=true \
  OIDC_ISSUER_URL=https://container.googleapis.com/v1/projects/hcm-hyperfleet/locations/europe-southwest1-a/clusters/hyperfleet-dev-<username>-eu1 \
  make install-hyperfleet
```

To call the API as a human, use a GCP identity token via `kubectl port-forward` (traffic is tunnelled through the encrypted k8s API server connection — avoids sending the token over cleartext HTTP):

```bash
kubectl port-forward svc/hyperfleet-api 8000:8000 &
TOKEN=$(gcloud auth print-identity-token)
curl -H "Authorization: Bearer $TOKEN" http://localhost:8000/api/hyperfleet/v1/clusters
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
│   ├── maestro/                     # Maestro umbrella chart (external dependency)
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
│   └── envs/gke/                    # Per-developer tfvars and tfbackend files
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
