# AGENTS.md

<!-- Maintainers: this file loads into every agent session (CLAUDE.md imports it). Keep it
under ~200 lines, link to README.md instead of copying its tables, and keep only what an
agent can't learn by reading the Makefile, env files and Helmfile. -->

## What this repo is

Infrastructure as code that provisions HyperFleet dev and e2e environments with **Makefile + Helmfile + Terraform**. The only Go code is two cloud functions under `functions/`.

`make help` is the entry point, and all developer operations go through it. `README.md` is the reference for every target and variable.

## Validation commands

```bash
make ci-validate     # terraform fmt + validate (terraform/ and terraform/oci/), helm lint, shellcheck, authorino templates
make ci-dry-run      # ci-validate + render checks: maestro, mock OIDC, network policies, namespace cleaner, desire delivery
```

Run `ci-validate` before proposing changes. `ci-dry-run` is the full pre-merge check, and Prow calls both.

Render one Helmfile environment without deploying: `HELMFILE_ENV=<env> make template-helmfile`.

Go functions: `make {test,build,lint}-lifecycle-function` (`functions/lifecycle-enforcer/`) and `make {test,build,lint}-oci-sweep-function` (`functions/oci-ci-sweep/`).

## Environments

| `HELMFILE_ENV` | Cluster | Broker | Generated values needed |
|----------------|---------|--------|-------------------------|
| `gcp` (default) | GKE via Terraform | Google Pub/Sub | `make install-terraform` writes `generated-values-from-terraform/` |
| `kind` | local kind | RabbitMQ | `make generate-rabbitmq-values` writes `generated-values-rabbitmq/` |
| `e2e-gcp` | existing GKE | Google Pub/Sub | none (broker config is hardcoded in Helmfile) |
| `e2e-kind` | local kind | RabbitMQ | none |

**Never edit or commit `generated-values-from-terraform/` or `generated-values-rabbitmq/`.** Both are generated and gitignored. Helmfile renders incorrectly or fails if they are missing. `make clean-generated` removes both.

Helmfile uses Go templates (`.gotmpl`) throughout. Per-environment adapter and sentinel lists live in `helmfile/environments/<env>/`, and the adapter config files they reference live in `helmfile/configs/{base,e2e}/adapters/`.

## Environment variable loading

The Makefile picks the env file by substring: a `HELMFILE_ENV` containing `gcp` sources `env.gcp`, and anything else sources `env.kind`. There are no `env.e2e-*` files. The e2e environments differ from their base only in Helmfile (adapter sets, hardcoded broker config) and in `NAMESPACE`/`RUN_ID`.

Every variable in the env files uses `?=`, so a CLI or shell value always wins:

```bash
HELMFILE_ENV=kind NAMESPACE=my-namespace REGISTRY=quay.io make install-hyperfleet
```

The Makefile `export`s everything, so Helmfile reads these values through `env "NAME"`. When you add a variable, define it in both env files and document it in README.md's variable table.

## Desire delivery (optional, e2e only)

`DESIRE_DELIVERY_ENABLED=true` swaps Maestro delivery for API → Sentinel → `cl-desire` adapter → Redis desire store → `hyperfleet-applier`. It deploys `helm/redis`, the applier chart (pulled from the `hyperfleet-applier` repo), and the single `cl-desire` adapter (`helmfile/environments/adapter-configs-desire.yaml.gotmpl`), which replaces the e2e adapter set. Full description: README.md, "Desire delivery (optional)".

- Only `e2e-kind` and `e2e-gcp` support it. `check-desire-delivery-env` fails other environments before any cluster work, and Helmfile `fail`s at render time.
- **Use the same toggle value for every command against a namespace.** The toggle selects which adapter set is in the Helmfile state, so installing or uninstalling with the other value leaves the previous set's adapter releases behind.
- On kind, `local-up-kind` skips Maestro and the AppliedManifestWorks CRD, builds the applier image (`PROJECTS_DIR` must contain `hyperfleet-applier`), and ends with `health-check-desire-delivery`, which fails if Maestro is present.
- `make validate-desire-delivery` (part of `ci-dry-run`) checks that the render has no Maestro reference, and that every `cl-desire` transport is `remote` with `target_cluster` equal to the run namespace, which is the store partition the applier serves. Keep that invariant when you edit the desire adapter config.
- `APPLIER_IMAGE_TAG` defaults to `latest` on GCP because the applier repo publishes no `dev` tag.

## Terraform

- Pinned CLI: `terraform 1.13.1` (`.tool-versions`). `.terraform.lock.hcl` is gitignored, so never commit it.
- Format from `terraform/`: `terraform fmt -recursive`. The check is `terraform fmt -check -recursive -diff`.
- Per-developer GKE setup (one time): copy `terraform/envs/gke/dev.tfvars.example` and `dev.tfbackend.example` to `dev-<username>.*`, then set `developer_name` and the state `prefix`. These files are gitignored, so never commit them. Remote state lives in the GCS bucket `hyperfleet-terraform-state`.
- `terraform/oci/` is a separate stack for the OCI CI compartment (quota, budget, sweep function). See `terraform/oci/README.md`.

## Helm charts

Local charts in `helm/`: `external-dns`, `hyperfleet-gateway`, `maestro`, `mock-oidc`, `namespace-cleaner`, `network-policies`, `rabbitmq`, `redis`. `rabbitmq` and `redis` are dev-only (no persistence, no auth or `guest/guest`) and not production-ready.

`helm/maestro/` is an umbrella chart. It pulls its dependencies from `openshift-online/maestro` through `helm-git` at `ref=main`. `helm/maestro/charts/` is gitignored and `Chart.lock` is committed. `install-maestro` and `lint-helm` run `helm dependency update` for you, but running `helm template` directly fails until you do.

Required non-standard plugins (`check-helm` and `check-helmfile` verify them):

```bash
helm plugin install https://github.com/aslafy-z/helm-git
helm plugin install https://github.com/databus23/helm-diff --verify=false
```

## Sibling repos

Charts for `hyperfleet-api`, `hyperfleet-sentinel`, `hyperfleet-adapter` and (with desire delivery only) `hyperfleet-applier` live in their own repos and are pulled at deploy time through `helm-git`. `CHART_ORG` and the `*_CHART_REF` variables select the org and ref.

For kind image builds, `PROJECTS_DIR` must be the parent directory of those repos (default: `~/openshift-hyperfleet`). Set `BUILD_IMAGES=false` to skip image builds.

## CI

There is no `.github/workflows/`. CI runs on **Prow** (OpenShift CI) through the `ci-validate`, `ci-dry-run`, `ci-test`, `ci-cleanup` and `ci-tf-env` targets. `OWNERS` enforces PR approval.

## Common gotchas

**`check-kubectl-context` checks the context name, not just the env.**
For `HELMFILE_ENV=kind` or `e2e-kind`, it hard-fails unless the current kubectl context contains `kind-`. Switch your kubeconfig context along with `HELMFILE_ENV`.

**`generate-rabbitmq-values` only works for `HELMFILE_ENV=kind`.**
For other environments it silently does nothing.

**`install-maestro` installs the AppliedManifestWorks CRD manually.**
The upstream Maestro chart's CRD install is broken. `install-maestro` applies the CRD from `open-cluster-management-io/api` before the chart and sets `agent.installWorkCRDs=false`. Do not remove or reorder these steps.

**The Authorino operator is a cluster-singleton prerequisite for gateway ext_authz.**
With `EXT_AUTHZ_ENABLED=true`, the `hyperfleet-gateway` chart renders `Authorino` and `AuthConfig` CRs. `install-hyperfleet` installs the pinned operator (`AUTHORINO_OPERATOR_VERSION`) first through `maybe-install-authorino-operator`. If you apply the CRs before the operator exists, Helmfile fails on unknown CRDs.

**OIDC defaults to the development-only mock issuer in every environment.**
Authenticated mock deployments emit a Helmfile warning; its in-memory signing keys are replaced on issuer rollout, invalidating minted tokens. **Never use mock mode in production.** Set `OIDC_ISSUER_MODE=external` and provide `OIDC_ISSUER_URL` for an external issuer; direct human OIDC with `AUTH_MODE=API` also needs `OIDC_JWKS_URL`.

**Terraform state locking is always disabled.**
`install-terraform` and `destroy-terraform` pass `-lock=false`. If an apply left a `terraform/errored.tfstate`, resolve it before re-running.

**`validate-terraform` uses no backend.**
It runs `terraform init -backend=false`, so it validates syntax only, not GCS access or credentials.

**`shellcheck` is skipped locally but required in CI.**
Without `shellcheck` installed, `make lint-shellcheck` warns and passes. With `$CI` set, it fails. Install it locally (`brew install shellcheck`).

## Commit message format

```
HYPERFLEET-XXX - <type>: <subject>
```

Types: `feat`, `fix`, `docs`, `refactor`, `chore`, `test`. There are no semver releases: infra changes deploy from `main`.
