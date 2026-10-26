# AGENTS.md

<!-- Maintainers: this file loads into every agent session (CLAUDE.md imports it). Keep it
under ~200 lines, link to README.md instead of copying its tables, and keep only what an
agent can't learn by reading the Makefile, env files and Helmfile. -->

## What this repo is

Infrastructure as code that provisions HyperFleet dev and e2e environments with **Makefile + Helmfile + Terraform**. The only Go code is two cloud functions under `functions/`.

`make help` is the entry point, and all developer operations go through it. `README.md` is the reference for every target and variable.

## Validation commands

```bash
make ci-validate     # terraform fmt (terraform/, ci/tools/) + validate (terraform/, terraform/oci/), helm lint, shellcheck, authorino templates
make ci-dry-run      # ci-validate + GKE network policy mode tests + render checks: network policies, namespace cleaner, desire delivery, fixture entities
```

Run `ci-validate` before proposing changes. `ci-dry-run` is the full pre-merge check, and Prow calls both.

Render one Helmfile environment without deploying: `HELMFILE_ENV=<env> make template-helmfile`.

Go functions: `make {test,build,lint}-lifecycle-function` (`functions/lifecycle-enforcer/`) and `make {test,build,lint}-oci-sweep-function` (`functions/oci-ci-sweep/`).

CI tools image (`ci/tools/`): `make build-ci-tools` and `make test-ci-tools`. See `ci/tools/README.md`.

## Environments

| `HELMFILE_ENV` | Cluster | Broker | Generated values needed |
|----------------|---------|--------|-------------------------|
| `gcp` (default) | GKE via Terraform | Google Pub/Sub | `make install-terraform` writes `generated-values-from-terraform/` |
| `kind` | local kind | RabbitMQ | `make generate-rabbitmq-values` writes `generated-values-rabbitmq/` |
| `e2e-gcp` | existing GKE | Google Pub/Sub | none (broker config is hardcoded in Helmfile) |
| `e2e-kind` | local kind | RabbitMQ | none |

**Never edit or commit `generated-values-from-terraform/` or `generated-values-rabbitmq/`.** Both are generated and gitignored. Helmfile renders incorrectly or fails if they are missing. `make clean-generated` removes both.

Helmfile uses Go templates (`.gotmpl`) throughout. Per-environment adapter and sentinel lists live in `helmfile/environments/<env>/`, and the adapter config files they reference live in `helmfile/configs/{base,e2e}/adapters/`.

## Fixture entities

Only `e2e-kind` and `e2e-gcp` load `fixtureEntities` from `helmfile/environments/e2e/fixture-entities.yaml`; the Helmfile rejects a nonempty override in any other environment. For every entity, `required_adapters` is derived from adapters whose `resourceType` equals its plural, and no match renders `[]`. Do not add kind-specific adapter branches. `make validate-fixture-entities` enforces both rules.

## Environment variable loading

The Makefile picks the env file by substring: a `HELMFILE_ENV` containing `gcp` sources `env.gcp`, and anything else sources `env.kind`. There are no `env.e2e-*` files. The e2e environments differ from their base only in Helmfile (adapter sets, hardcoded broker config) and in `NAMESPACE`/`RUN_ID`.

Every variable in the env files uses `?=`, so a CLI or shell value always wins:

```bash
HELMFILE_ENV=kind NAMESPACE=my-namespace REGISTRY=quay.io make install-hyperfleet
```

The Makefile `export`s everything, so Helmfile reads these values through `env "NAME"`. When you add a variable, define it in both env files and document it in README.md's variable table.

## Desire delivery

Every environment delivers through API → Sentinel → remote adapter → Redis desire store → `hyperfleet-applier`. Helmfile deploys `helm/redis`, the applier chart (pulled from the `hyperfleet-applier` repo), and one remote adapter: `cl-desire` in `e2e-kind`/`e2e-gcp`, `adapter2` in `kind`/`gcp`. The remote adapter runs the task in `helmfile/configs/base/adapters/remote/` (shared by all four environments) with the deployment config in `helmfile/values/remote-adapter.yaml.gotmpl`. Full description: README.md, "Desire delivery".

- A remote adapter entry sets `desireStoreClient: true`. The `redis-ingress` NetworkPolicy admits only those adapters and the applier, and their releases carry the `desire-store-client` label.
- `make validate-desire-delivery` (part of `ci-dry-run`) checks, for every environment and every `desire-store-client` release, that each remote adapter transport is `remote` with `target_cluster` equal to the run namespace, which is the store partition the applier serves, and that Redis admits the adapter. Keep that invariant when you edit the remote adapter config.
- Kind image builds always build the applier, so `PROJECTS_DIR` must contain `hyperfleet-applier` (or set `BUILD_IMAGES=false`).
- `APPLIER_IMAGE_TAG` defaults to `latest` on GCP because the applier repo publishes no `dev` tag.

## Terraform

- Pinned CLI: `terraform 1.13.1` (`.tool-versions`). `.terraform.lock.hcl` is gitignored, so never commit it.
- Format from `terraform/`: `terraform fmt -recursive`. The check is `terraform fmt -check -recursive -diff`.
- Per-developer GKE setup (one time): copy `terraform/envs/gke/dev.tfvars.example` and `dev.tfbackend.example` to `dev-<username>.*`, then set `developer_name` and the state `prefix`. These files are gitignored, so never commit them. Remote state lives in the GCS bucket `hyperfleet-terraform-state`.
- `terraform/oci/` is a separate stack for the OCI CI compartment (quota, budget, sweep function). See `terraform/oci/README.md`.

## Helm charts

Local charts in `helm/`: `external-dns`, `hyperfleet-e2e`, `hyperfleet-gateway`, `mock-oidc`, `namespace-cleaner`, `network-policies`, `rabbitmq`, `redis`. `hyperfleet-e2e` is installed only in e2e Helmfile environments. `rabbitmq` and `redis` are dev-only (no persistence, no auth or `guest/guest`) and not production-ready.

Required non-standard plugins (`check-helm` and `check-helmfile` verify them):

```bash
helm plugin install https://github.com/aslafy-z/helm-git
helm plugin install https://github.com/databus23/helm-diff --verify=false
```

## Sibling repos

Charts for `hyperfleet-api`, `hyperfleet-sentinel`, `hyperfleet-adapter` and `hyperfleet-applier` live in their own repos and are pulled at deploy time through `helm-git`. `CHART_ORG` and the `*_CHART_REF` variables select the org and ref.

For kind image builds, `PROJECTS_DIR` must be the parent directory of those repos (default: `~/openshift-hyperfleet`). Set `BUILD_IMAGES=false` to skip image builds.

## CI

There is no `.github/workflows/`. CI runs on **Prow** (OpenShift CI). Prow calls `ci-dry-run` (which runs `ci-validate`) and `ci-tf-env`, plus the desire delivery and Terraform targets directly. `ci/tools/` defines the build root image for the infra Prow jobs; the release `images` variant builds, tests and promotes it. `ci-test` and `ci-cleanup` are the local equivalents of the Prow integration job. `OWNERS` enforces PR approval.

## Common gotchas

**`check-kubectl-context` checks the context name, not just the env.**
For `HELMFILE_ENV=kind` or `e2e-kind`, it hard-fails unless the current kubectl context contains `kind-`. Switch your kubeconfig context along with `HELMFILE_ENV`.

**`generate-rabbitmq-values` only works for `HELMFILE_ENV=kind`.**
For other environments it silently does nothing.

**The Authorino operator is a cluster-singleton prerequisite for gateway ext_authz.**
With `EXT_AUTHZ_ENABLED=true`, the `hyperfleet-gateway` chart renders `Authorino` and `AuthConfig` CRs. `install-hyperfleet` installs the pinned operator (`AUTHORINO_OPERATOR_VERSION`) first through `maybe-install-authorino-operator`. If you apply the CRs before the operator exists, Helmfile fails on unknown CRDs.

**OIDC defaults to mock in E2E environments.** `e2e-gcp` and `e2e-kind` use the namespace-local mock issuer; `gcp` and `kind` default to an external issuer. Set `OIDC_ISSUER_URL` for authenticated external deployments. Set `OIDC_ISSUER_MODE` explicitly to override an environment default. Authenticated mock deployments emit a Helmfile warning; its in-memory signing keys are replaced on issuer rollout, invalidating minted tokens. **Never use mock mode in production.** Direct human OIDC with `AUTH_MODE=API` also needs `OIDC_JWKS_URL`.

**Terraform state locking is always disabled.**
`install-terraform` and `destroy-terraform` pass `-lock=false`. If an apply left a `terraform/errored.tfstate`, resolve it before re-running.

**The CI tools image installs Terraform providers only from its mirror.**
`ci/tools/providers.tf` pins one version each of the Google, Google Beta, local and OCI providers, and `terraform init` in the image cannot download them. If you change a provider constraint in `terraform/` so that it excludes the mirrored version, validate fails at `terraform init`. Bump `ci/tools/providers.tf` to a version both constraints accept first. A new provider also goes in both lists in `ci/tools/terraformrc`.

**`validate-terraform` uses no backend.**
It runs `terraform init -backend=false`, so it validates syntax only, not GCS access or credentials.

**`shellcheck` is skipped locally but required in CI.**
Without `shellcheck` installed, `make lint-shellcheck` warns and passes. With `$CI` set, it fails. Install it locally (`brew install shellcheck`).
