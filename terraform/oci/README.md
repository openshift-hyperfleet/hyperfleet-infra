# HyperFleet OCI CI Infrastructure

Terraform for the `hyperfleet-ci` compartment: a quota fence, a scheduled
teardown sweep, and a budget. This is the foundation
[HYPERFLEET-1563](https://redhat.atlassian.net/browse/HYPERFLEET-1563)'s e2e
CI job runs against.

## What this creates

| Resource                   | Purpose                                                                 |
| --------------------------- | ------------------------------------------------------------------------ |
| `hyperfleet-ci` compartment | Isolates CI-created OKE clusters and their dependents from everything else in the team compartment |
| Compartment quota policy    | Caps compute cores and (if the tenancy exposes it) concurrent OKE clusters |
| Budget + alert rules        | $150/month budget on the compartment's spend, alerting at 50/80/100% actual and 100% forecast |
| `oci-ci-sweep` function     | Scheduled (hourly by default) sweep that deletes clusters, load balancers, block volumes, and DB systems older than the run window |

`hyperfleet-ci` is a sibling of the team's existing `hyperfleet-sandbox`,
`hyperfleet-poc`, and `hyperfleet-demos` compartments under the `HyperFleet`
team compartment — never directly inside `HyperFleet` itself. Set
`team_compartment_id` to `HyperFleet`'s own OCID, not one of those
sub-compartments'. This compartment is dedicated to the OCI e2e CI suite,
not a general-purpose sandbox — for ad hoc experiments, use
`hyperfleet-sandbox` instead.

## Sweep policy

A scheduled OCI Function sweeps the compartment and deletes anything older
than the run window: OKE clusters, load balancers, block volumes, and DB
systems.

| Setting | Value |
|---|---|
| Run window | `sweep_run_window_hours` (default 8h) |
| Schedule | `sweep_schedule_recurrence` (default hourly, `0 * * * *`) |
| Exemption | Freeform tag `hyperfleet-keep=true` holds a resource regardless of age, for manual debugging |

The sweep only handles those four resource types. It does **not** delete
network load balancers (the newer NLB service, distinct from the classic
load balancers it does sweep), standalone compute instances, node pools,
VCNs/subnets, or object storage buckets. Anything the e2e job creates
outside those four types must be torn down by the job itself; the
compartment quota and budget are the backstops for those.

The `hyperfleet-keep=true` exemption is evaluated per resource, against that
resource's own freeform tags — it is **not** inherited. OKE doesn't
propagate a cluster's tags to the block volumes or load balancers it
provisions, so tagging a cluster `hyperfleet-keep=true` holds only the
cluster object; the sweep can still delete its dependent volumes and load
balancers once they age out. To pin a whole cluster's footprint for
debugging, tag each of its resources.

The sweep is the **backstop**, not the primary cleanup mechanism: the e2e CI
job is expected to tear down every billable resource at the end of each run
(including failed runs). The sweep only catches what that per-run teardown
misses — a leaked resource costs at most a few hours of spend before the
sweep removes it, rather than sitting forgotten indefinitely. That bound
only holds for a non-exempt resource once the sweep actually runs and
deletes successfully: a resource tagged `hyperfleet-keep=true` is held
indefinitely by design, and a sweep left in `DRY_RUN` or otherwise not
running normally won't delete anything at all.

The sweep does not send notifications of any kind; it only logs its
decisions (Logging service, `oci-ci-sweep` function).

## Quota policy

`quota_statements` (see `ci.tfvars.example`) has no hardcoded default in the
module — confirmed live against the rhelcert tenancy on 2026-09-04 instead of
guessed:

- `compute-core` quota family, `standard-e4-core-count` name (region limit
  11111 in us-sanjose-1 — plenty of headroom for a compartment cap of 16).
  The quota family is `compute-core`, **not** the `compute` service name:
  the statement family must match the limit's `supported-quota-families`, or
  the API rejects it with "not a valid quota name for service compute".
- `container-engine` family, `cluster-count` name — Container Engine *does*
  expose a compartment-quota-manageable cluster count in this tenancy
  (region limit 15, 0 used), so the 2-concurrent-cluster cap is a real IAM
  guarantee, not a soft check in the sweep function.

`hyperfleet-ci` is nested under `HyperFleet`, so the statements reference it
by path (`in compartment HyperFleet:hyperfleet-ci`) — a bare compartment name
only resolves for direct children of the tenancy root.

At list price, a running OKE cluster with three small nodes costs about
$7/day. The quota is a sanity cap on concurrency, not a mathematical
guarantee that spend stays under budget — a bug that kept both quota slots
occupied for a full month would still cost roughly $420, well over budget.
The budget alerts (below) are the real early-warning mechanism: at 2
concurrent clusters, the 50/80/100% thresholds fire after roughly 11, 17,
and 21 cluster-days of usage respectively, out of the ~60 cluster-days
theoretically possible in a 30-day month — comfortably before the worst
case is reached.

If the worker node shape changes, re-derive the compute quota name with the
command below, and read `supported-quota-families` on the matching limit for
the statement's quota family (check `are-quotas-supported`, not the
unpopulated `is-quota-managed`):

```bash
oci limits definition list --compartment-id "$TENANCY_OCID" --service-name compute
```

Applying a `quota_statements` change requires an identity with the `quota`
resource-type manage permission at the tenancy level (`allow group
<your-group> to manage quota in tenancy`) — not full tenancy
administration. `oci_limits_quota` is created at the tenancy root even
though its statements target `hyperfleet-ci` specifically, so a
compartment-scoped identity is not sufficient.

The same applies to the sweep function's IAM: dynamic groups live at the
tenancy root, so applying this stack also needs `manage dynamic-groups in
tenancy` (and `manage policies` in the CI compartment for the policies that
reference them). A purely compartment-scoped identity can create the
compartment, VCN, budget, and function, but will fail on the dynamic
groups.

## Managed PostgreSQL (Oracle deployment path)

`postgresql_enabled` (default `false`) scaffolds an **OCI Database with
PostgreSQL** db system — the managed instance decided on for the Oracle
deployment path in the architecture repo's
[ADR 0022](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/adrs/0022-oci-managed-postgresql.md).
Self-managed PostgreSQL (the existing embedded Helm sub-charts) remains the
answer for local and dev work; this is not wired into any real deployment
yet.

When enabling it, set `postgresql_compartment_id` to a compartment **other
than** `hyperfleet-ci`. The `oci-ci-sweep` function (see [Sweep
policy](#sweep-policy)) deletes DB systems in `hyperfleet-ci` older than its
run window, which would destroy the managed instance if it were created
there. This is enforced, not just documented: the `postgresql` module takes
the CI compartment's OCID as `ci_compartment_id` and fails a
`lifecycle.precondition` if `compartment_id` matches it.
`postgresql_subnet_id` and `postgresql_admin_password_secret_id` (a Vault
secret OCID — plaintext admin passwords aren't supported) are also required
once enabled; variable `validation` blocks enforce those two.

The defaults for shape (`VM.Standard.E5.Flex`) and PostgreSQL version (`17`)
come from the settings validated live against the tenancy in ADR 0022 —
re-verify them there if the target shape family ever changes.
`postgresql_availability_domain` defaults to `null`, which derives the AD
from whatever `region` is set to (an `oci_identity_availability_domains`
lookup in the module) rather than hardcoding one; with
`postgresql_storage_is_regionally_durable = false` (the default), that only
resolves to a single AD in `us-sanjose-1` today because it's the tenancy's
only one there.

## Notifications

**Owner:** `#hcm-hyperfleet-team`.

Budget alerts (50/80/100% actual spend, 100% forecast) are delivered by
email, using `oci_budget_alert_rule`'s built-in `recipients` field — no
Slack app, webhook, or Notifications-topic wiring needed. Set the recipients
via `budget_alert_recipients` in your (gitignored) `ci.tfvars` — prefer a team
distribution list over individual addresses, and don't commit personal
addresses to the checked-in example.

## The sweep function's network

OCI Functions always run inside a VCN subnet even though they're
serverless. `terraform/modules/lifecycle/oci/network.tf` creates a small,
dedicated VCN with a private subnet — the function reaches other OCI service
APIs (Container Engine, Load Balancer, Block Storage, Database) over the OCI
backbone via a service gateway, so no NAT gateway or internet egress is
needed.

## Usage

```bash
cd terraform/oci
cp ci.tfbackend.example ci.tfbackend   # edit prefix if needed
cp ci.tfvars.example ci.tfvars         # fill in tenancy/compartment/quota/recipients

terraform init -backend-config=ci.tfbackend
terraform plan -var-file=ci.tfvars
terraform apply -var-file=ci.tfvars
```

The sweep function's image is built and pushed separately (see
[`functions/oci-ci-sweep/README.md`](../../functions/oci-ci-sweep/README.md))
— Terraform creates the OCIR repository but does not build or push images.
OCI Functions requires a tag reference in `sweep_function_image` (a digest
reference is rejected), so the immutable pin is set separately in
`sweep_function_image_digest`, which is what OCI actually pulls by; Terraform
validation enforces the tag/digest split. The function README shows how to
read the digest back after pushing. `sweep_dry_run` defaults to `true`; flip
it to `false` once you've confirmed the sweep's dry-run log output looks
right.

### View compartment contents (read-only, any team member)

```bash
oci iam compartment list --compartment-id "$HYPERFLEET_COMPARTMENT_OCID" \
  --query "data[?name=='hyperfleet-ci']"

oci ce cluster list --compartment-id "$HYPERFLEET_CI_OCID"
```

### View Terraform state and outputs

```bash
cd terraform/oci
terraform init -backend-config=ci.tfbackend
terraform state list
terraform output
```

## Auth

Set `oci_auth` to match how you're authenticated:

- `"ApiKey"` (default): durable API key, needs `oci_user_ocid`,
  `oci_fingerprint`, `oci_private_key_path`.
- `"SecurityToken"`: browser SSO session token from `oci session
  authenticate`, needs `oci_config_file_profile`.

## Remote state

Same GCS backend as the GKE stacks (`hyperfleet-terraform-state`), under
`terraform/state/oci-ci`. See the top-level [`terraform/README.md`](../README.md)
for backend setup and team access.

## Key configuration files

| File | Purpose |
|---|---|
| `terraform/oci/ci.tfvars.example` | Compartment, quota, budget, and sweep configuration |
| `terraform/oci/ci.tfbackend.example` | Remote state configuration |
| `terraform/oci/main.tf` | Root module wiring the compartment, quota, budget, and sweep modules |
| `terraform/modules/{compartment,quota,budget,lifecycle,postgresql}/oci/` | Individual resource modules |
| `functions/oci-ci-sweep/` | The sweep function's Go source |

## Troubleshooting

### Sweep isn't removing an expected resource

Check the function's logs (Logging service, `oci-ci-sweep` function) for
the per-resource action and reason. Common causes: the resource carries
`hyperfleet-keep=true`, it's younger than the run window, or `DRY_RUN` is
still `true` on the function.

### Quota apply fails with a permissions error

`oci_limits_quota` requires `manage quota in tenancy` permissions (see
[Quota policy](#quota-policy)) — a compartment-scoped identity is not
sufficient.

### Budget alert emails never arrived

Check `budget_alert_recipients` in `ci.tfvars` for typos, and check
spam/junk folders — the alert rule's email delivery is OCI's built-in
mechanism, not a separate subscription to confirm.

## Additional documentation

- **Sweep function internals**: [`functions/oci-ci-sweep/README.md`](../../functions/oci-ci-sweep/README.md)
