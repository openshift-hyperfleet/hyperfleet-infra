# AGENTS.md

## What this repo is

Pure infrastructure-as-code. No application code, no compiled artifacts. Provisions HyperFleet dev environments using **Makefile + Helmfile + Terraform**.

`make help` is the canonical entry point — all developer operations go through it.

---

## Validation / CI commands

```bash
make ci-validate     # validate terraform + lint helm + lint shellcheck
make ci-dry-run      # ci-validate + validate maestro
```

Run `ci-validate` before proposing changes. `ci-dry-run` is the full pre-merge check.

Individual checks:
```bash
make validate-terraform   # terraform init (no backend) + fmt check + validate
make lint-helm            # helm lint all charts under helm/*/
make lint-shellcheck      # shellcheck all *.sh
make validate-maestro     # renders maestro chart to /dev/null
```

Template/dry-run all four Helmfile environments explicitly:
```bash
# environment specific
HELMFILE_ENV=<env> make template-helmfile
# example:
HELMFILE_ENV=gcp make template-helmfile
```

---

## Terraform formatting

Terraform lock file (`terraform/.terraform.lock.hcl`) is **gitignored** — do not commit it.

Format check runs from `terraform/`:
```bash
terraform fmt -check -recursive -diff
terraform fmt -recursive   # auto-fix
```

Pinned version: `terraform 1.13.1` (asdf, `.tool-versions`). Providers: `hashicorp/google 5.45.2`, `hashicorp/google-beta 5.45.2`, `hashicorp/local 2.9.0`.

---

## Generated values — must exist before helmfile deploy

**Do not edit files in `generated-values-from-terraform/` or `generated-values-rabbitmq/` — both directories are auto-generated and gitignored.**

| Env | How values are generated | Required before |
|-----|--------------------------|-----------------|
| `gcp` | `make install-terraform` (Terraform writes via `local_file`) | `make install-hyperfleet` |
| `kind` | `make generate-rabbitmq-values` (shell script) | `make install-hyperfleet` |
| `e2e-gcp` / `e2e-kind` | Not needed — broker configs hardcoded in helmfile | — |

Helmfile will fail silently or render incorrectly if these files are missing.

`make clean-generated` removes both directories.

---

## Environment variable loading

The Makefile selects the env file based on `HELMFILE_ENV`:
- contains `gcp` → sources `env.gcp`
- does not contain `gcp` → sources `env.kind` (so `kind`, `e2e-kind`, etc.)

All variables in those files use `?=`, so **any variable can be overridden on the CLI** and the env file value is ignored:

```bash
HELMFILE_ENV=kind NAMESPACE=my-namespace REGISTRY=quay.io make install-hyperfleet
```

For persistent personal overrides, pass variables on the CLI or set them in your shell environment before invoking make.

Key variables:

| Variable | GCP default | kind default | Notes |
|----------|------------|--------------|-------|
| `HELMFILE_ENV` | `gcp` | `kind` | Also `e2e-gcp`, `e2e-kind` |
| `NAMESPACE` | `hyperfleet` | `hyperfleet-local` | e2e envs use `hyperfleet-e2e[-$USER]` |
| `REGISTRY` | `quay.io` | `localhost` | |
| `TF_ENV` | `dev` | N/A | Selects `envs/gke/<TF_ENV>.tfvars` |
| `BROKER_TYPE` | `googlepubsub` | `rabbitmq` | |
| `API_IMAGE_TAG` | `dev` | `local` | |
| `IMAGE_PULL_POLICY` | `Always` | `IfNotPresent` | |

---

## Terraform per-developer setup (GCP, one-time)

```bash
cd terraform
cp envs/gke/dev.tfvars.example envs/gke/dev-<username>.tfvars
cp envs/gke/dev.tfbackend.example envs/gke/dev-<username>.tfbackend
# Set developer_name = "<username>" in tfvars
# Set prefix = "terraform/state/dev-<username>" in tfbackend
```

These files are gitignored — never commit personal tfvars/tfbackend. Remote state uses GCS bucket `hyperfleet-terraform-state`.

---

## Helm charts and dependencies

Two local charts under `helm/`:
- `helm/maestro/` — umbrella chart; dependencies pulled from `github.com/openshift-online/maestro` via `helm-git` plugin at `ref=main`
- `helm/rabbitmq/` — dev-only, NOT production-ready (no StatefulSet, hardcoded `guest/guest`)

`helm/maestro/charts/` is gitignored; `Chart.lock` is committed. The `install-maestro` target runs `helm dependency update` automatically.

**Required Helm plugins** (not standard):
```bash
helm plugin install https://github.com/aslafy-z/helm-git
helm plugin install https://github.com/databus23/helm-diff --verify=false
```

---

## Helmfile environments

Four environments, two broker backends:

| `HELMFILE_ENV` | Backend | Notes |
|----------------|---------|-------|
| `gcp` | Google Pub/Sub | Requires Terraform-generated values |
| `kind` | RabbitMQ | Requires script-generated values |
| `e2e-gcp` | Google Pub/Sub | Hardcoded configs, uses `$NAMESPACE` |
| `e2e-kind` | RabbitMQ | Hardcoded configs, uses `$NAMESPACE` |

Helmfile uses Go template syntax (`.gotmpl` extension) throughout.

---

## Sibling repos

Helm charts for `hyperfleet-api`, `hyperfleet-sentinel`, and `hyperfleet-adapter` live in their respective sibling repos and are pulled at deploy time via `helm-git`. The `CHART_ORG` and `API_CHART_REF` variables control which org/ref is used.

For kind image builds, `PROJECTS_DIR` must point to the parent directory containing those repos (default: `~/openshift-hyperfleet`).

---

## No CI workflows in this repo

There is no `.github/workflows/`. CI is managed by **Prow** (OpenShift CI). The `ci-validate`, `ci-dry-run`, `ci-test`, and `ci-cleanup` Make targets are designed to be called by Prow. PR approval is enforced via `OWNERS`.

---

## Common gotchas

**`generate-rabbitmq-values` only works for `HELMFILE_ENV=kind`**
Running it for any other env silently no-ops. E2E envs (`e2e-kind`, `e2e-gcp`) have broker configs hardcoded in helmfile and need no generated files.

**`check-kubectl-context` enforces context shape, not just env**
`check-kubectl-context`, hard-fails if your current kubectl context doesn't output `kind-` if your `HELMFILE_ENV=kind` or `HELMFILE_ENV=e2e-kind`. Switching `HELMFILE_ENV` to `e2e-kind` or `kind` without switching your kubeconfig context to the cluster will fail immediately.

**`install-maestro` installs the AppliedManifestWorks CRD manually**
The upstream Maestro Helm chart CRD install is broken. `install-maestro` works around this by applying the CRD directly from `open-cluster-management-io/api` before the chart, and sets `--set agent.installWorkCRDs=false`. Do not remove or reorder these steps.

**Terraform state lock is always disabled**
`make install-terraform` and `make destroy-terraform` both pass `-lock=false`. If a previous apply left `terraform/errored.tfstate` (currently present in this repo), resolve it before re-running — Terraform may use it as a fallback.

**`validate-terraform` uses no backend**
`make validate-terraform` runs `terraform init -backend=false`. It validates syntax only; it does not test connectivity to GCS or check that provider credentials work.

**`shellcheck` is silently skipped locally but required in CI**
`make lint-shellcheck` skips without error if `shellcheck` is not installed. In CI (`$CI` set), it hard-fails instead. Install it locally to catch issues before push: `brew install shellcheck`.

**`helm/maestro/charts/` is gitignored; `Chart.lock` is not**
Running `helm dependency update helm/maestro` is required before any Maestro install. The `install-maestro` target does this automatically, but running `helm install` or `helm template` on the chart directly will fail if `charts/` is absent.

**E2E environments share env files with their base environments**
`HELMFILE_ENV=e2e-kind` sources `env.kind`, and `HELMFILE_ENV=e2e-gcp` sources `env.gcp` — no separate `env.e2e-*` files exist. The Makefile uses substring matching (`findstring gcp`) to choose between the two env files. The distinction between base and e2e environments is in Helmfile only (different adapter configs, hardcoded broker settings).

---

## Commit message format

```
HYPERFLEET-XXX - <type>: <subject>
```

Types: `feat`, `fix`, `docs`, `refactor`, `chore`, `test`. No semver releases — infra changes deploy from `main`.
