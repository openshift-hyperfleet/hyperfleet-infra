# Lifecycle Enforcer

A Cloud Function (Go) that enforces the [GCP Developer Cluster Lifecycle Policy](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/docs/gcp-developer-cluster-lifecycle.md).

Runs hourly via Cloud Scheduler, iterates all GKE clusters in `hcm-hyperfleet`, and enforces:

- **Idle shutdown** — scales node pools to 0 when all nodes have been running >12h
- **TTL expiration** — scales to 0 when the `ttl` label date has passed; deletes the cluster after 48h
- **Missing owner** — scales to 0 on detection; deletes after 7 days
- **Exempt clusters** — `environment: cicd` and `hyperfleet-dev-ci-infra-*` are skipped

## Architecture

```text
Cloud Scheduler (hourly, UTC)
    │
    ▼  HTTP POST + OIDC token
Cloud Function Gen2 (lifecycle-enforcer)
    │
    ├─ Lists all GKE clusters in hcm-hyperfleet
    │
    ├─ For each cluster:
    │   ├─ Fetches node pools + instances via Compute API
    │   ├─ EvaluateCluster() → Decision (skip/shutdown/delete/label-only)
    │   └─ Executes the action (or logs if DRY_RUN=true)
    │
    └─ Returns JSON with per-cluster results
```

### Infrastructure (Terraform)

| Resource            | Purpose                                                                         |
| ------------------- | ------------------------------------------------------------------------------- |
| Cloud Function Gen2 | Iterates clusters, evaluates rules, executes actions                            |
| Cloud Scheduler     | Hourly HTTP POST trigger with OIDC auth                                         |
| GCS Bucket          | Stores the function source zip                                                  |
| Service Accounts    | Function SA (`container.admin`, `compute.viewer`), Scheduler SA (`run.invoker`) |

Terraform module: [`terraform/modules/lifecycle/`](../../terraform/modules/lifecycle/)

## Enforcement Rules

### Decision priority

1. **Exempt check** — skip if `environment: cicd` or name starts with `hyperfleet-dev-ci-infra-`
2. **Deletion check** — if `shutdown-date` label exists and grace period expired:
   - Missing owner + >7 days → delete
   - TTL expired + >48h → delete
3. **Shutdown check** — if cluster is running (node count > 0):
   - Missing `owner` label → scale to 0, set `shutdown-date`
   - Missing or expired `ttl` label → scale to 0, set `shutdown-date`
   - All nodes running >12h → scale to 0 (no `shutdown-date`, no deletion path)
4. **No action** — cluster is healthy

### Labels

| Label           | Set by                             | Purpose                                                           |
| --------------- | ---------------------------------- | ----------------------------------------------------------------- |
| `environment`   | Terraform (`var.environment`)      | `dev` = enforced, `cicd` = exempt                                 |
| `ttl`           | Terraform (`plantimestamp()` + 5d) | Expiration date (`YYYY-MM-DD`). Re-applying Terraform renews it   |
| `owner`         | Terraform (`var.developer_name`)   | Cluster ownership                                                 |
| `shutdown-date` | Enforcer function                  | Tracks when a cluster was first shut down (grace period tracking) |

### State machine

```text
                    ┌─────────────────────────────────────────────┐
                    │              RUNNING                        │
                    │  (nodes > 0, TTL valid, owner present)      │
                    └──────────┬──────────────┬──────────────┬────┘
                               │              │              │
                    idle >12h  │  TTL expired │  no owner    │
                               ▼              ▼              ▼
                    ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
                    │  SCALED DOWN │  │  SCALED DOWN │  │  SCALED DOWN │
                    │  (idle)      │  │  +shutdown-  │  │  +shutdown-  │
                    │  no deletion │  │   date label │  │   date label │
                    │  path        │  │              │  │              │
                    └──────────────┘  └──────┬───────┘  └──────┬───────┘
                                             │                 │
                    developer scales         │ 48h             │ 7 days
                    back up anytime          ▼                 ▼
                                      ┌──────────┐     ┌──────────┐
                                      │ DELETED  │     │ DELETED  │
                                      └──────────┘     └──────────┘
```

## Scaling back up (daily workflow)

The idle shutdown scales your cluster to 0 once all nodes have been running for more than 12 hours. To start working the next day, scale your node pool back up:

```bash
gcloud container clusters resize hyperfleet-dev-<username> \
    --node-pool hyperfleet-dev-<username>-pool \
    --num-nodes 1 \
    --zone us-central1-a \
    --project hcm-hyperfleet \
    --quiet
```

No TTL renewal is needed — the idle shutdown does not affect your TTL or trigger the deletion path.

## Renewing your cluster (TTL)

The `ttl` label is set to current date + 5 days on every `terraform apply`. When your TTL is about to expire (or already expired), renew it:

```bash
make install-terraform
```

This resets the TTL and clears the enforcement state. If the cluster was already scaled to 0, you also need to scale the node pool back up (see above).

## Deployment

The lifecycle enforcer is deployed from the **shared Terraform module** (`terraform/shared/`), not from individual developer states. It is always deployed when running `terraform apply` in the shared directory.

### Apply

```bash
cd terraform/shared
terraform apply
```

### Rollout

1. Deploy with `lifecycle_enforcer_dry_run = true` (default) — logs all actions without executing
2. Check logs in Cloud Logging:
   ```text
   resource.type="cloud_run_revision"
   resource.labels.service_name="lifecycle-enforcer"
   ```
3. Add TTL labels to existing clusters:
   ```bash
   DRY_RUN=false make add-ttl-labels
   ```
4. When confident, set `lifecycle_enforcer_dry_run = false` in `terraform/shared/` and re-apply

### Configuration (shared module variables)

| Variable                      | Default     | Description                                   |
| ----------------------------- | ----------- | --------------------------------------------- |
| `lifecycle_enforcer_dry_run`  | `true`      | Log actions without executing                 |
| `lifecycle_enforcer_schedule` | `0 * * * *` | Cloud Scheduler cron expression (hourly)      |

### Environment variables (Cloud Function)

| Variable         | Default          | Description                                   |
| ---------------- | ---------------- | --------------------------------------------- |
| `PROJECT_ID`     | *(required)*     | GCP project to scan for clusters              |
| `DRY_RUN`        | `true`           | Set to `false` to execute enforcement actions |

## Development

### Run tests

```bash
make test-lifecycle-function
```

### Build

```bash
make build-lifecycle-function
```

### Lint

```bash
make lint-lifecycle-function
```

### Code structure

| File               | Purpose                                                                      |
| ------------------ | ---------------------------------------------------------------------------- |
| `decision.go`      | Pure enforcement decision logic — no GCP SDK dependency, fully unit-testable |
| `decision_test.go` | Table-driven tests covering all enforcement scenarios                        |
| `function.go`      | Cloud Function entry point, GKE/Compute API client, action executor          |

The decision logic is intentionally separated from the GKE API interaction. `EvaluateCluster()` is a pure function that takes a `ClusterInfo` struct and returns a `Decision` — no mocking needed for tests.
