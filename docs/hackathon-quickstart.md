# HyperFleet Ignition Day — Participant Quickstart

## What Is Ignition Day?

A half-day hackathon where you dog-food HyperFleet, break silos, and hunt bugs. Pick a scenario, work through three sprints (guided → free exploration → deep dive), and report what you find.

## Your Environment

Three GKE clusters are provisioned, one per scenario group:

| Cluster | Scenarios | Namespace | What's Running |
|---------|-----------|-----------|---------------|
| **Dog Food** | 1 (Fresh Eyes), 2 (Reconciliation Loop) | `hyperfleet-healthy` | Full HyperFleet stack. Healthy deployment. |
| **Dog Food** | 3 (Something Is Wrong — Americas) | `hyperfleet-broken-americas` | Broken adapter1. Isolated per-region. |
| **Dog Food** | 3 (Something Is Wrong — Europe) | `hyperfleet-broken-europe` | Broken adapter1. Isolated per-region. |
| **Build** | 4 (Build Your Own Adapter) | `hyperfleet` | HyperFleet API + sentinels + broker. No adapters — you deploy your own. |
| **Operate** | 5 (Shard the Sentinel) | `hyperfleet` | Full stack with catch-all sentinel + pre-seeded regional clusters. |

### Access

Your facilitator will provide:
- **kubectl context** for your cluster
- **API endpoint** (LoadBalancer URL or port-forward instructions)
- **RabbitMQ Management UI** at port 15672 (guest/guest)
- **Grafana** at the monitoring LoadBalancer (admin/ignition)

## Scenarios at a Glance

| # | Scenario | Cluster | What You Do |
|---|----------|---------|-------------|
| 1 | First Cluster, Fresh Eyes | Dog Food (healthy) | Dog-food the API: create clusters, node pools, PATCH, DELETE |
| 2 | The Reconciliation Loop | Dog Food (healthy) | Trace Sentinel → broker → adapters → status → loop |
| 3 | Something Is Wrong | Dog Food (your region's broken namespace) | Debug a stuck cluster — one adapter is deliberately broken |
| 4 | Build Your Own Adapter | Build | Write adapter config from the docs, deploy via Helm, join the loop |
| 5 | Shard the Sentinel | Operate | Scale down the catch-all, deploy region-specific sentinels |

## For Scenario 4: Building an Adapter

Skeleton configs are at:
```text
helmfile/configs/hackathon/adapters/skeleton/
├── adapter-config.yaml           # Adapter identity and client connections
└── adapter-task-config.yaml      # Task logic: params, preconditions, resources, status
```

**Your job:** Fill in the `TODO:` sections using the [architecture docs](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/components/adapter/framework/adapter-frame-design.md).

**Deploy your adapter:**
```bash
# From your participant namespace
helm upgrade --install my-adapter hyperfleet-adapter/hyperfleet-adapter \
  --namespace hackathon-<your-name> \
  --set-file adapterConfig.yaml=<path-to-your-adapter-config.yaml> \
  --set-file adapterTaskConfig.yaml=<path-to-your-adapter-task-config.yaml> \
  --set broker.type=rabbitmq \
  --set broker.rabbitmq.url="amqp://guest:guest@rabbitmq.hyperfleet:5672" \
  --set broker.rabbitmq.queue="hyperfleet-clusters-my-adapter" \
  --set broker.rabbitmq.exchange="hyperfleet-clusters" \
  --set 'broker.rabbitmq.routingKey=#'
```

## For Scenario 5: Sharding the Sentinel

Skeleton config is at:
```text
helmfile/configs/hackathon/sentinels/skeleton/
└── sentinel-values.yaml          # Sentinel identity, resource type, selectors
```

Pre-seeded clusters have labels: `region=us-east`, `region=us-west`, `region=eu-west`.

**Your job:** Scale down the catch-all sentinel and deploy region-specific ones using the [sentinel docs](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/components/sentinel/sentinel.md).

## The Three Sprints

| Sprint | Focus |
|--------|-------|
| **Sprint 1 — Guided** | Follow the scenario's guided steps. Complete the happy path, note every friction point. |
| **Sprint 2 — Free exploration** | Go off-script. Edge cases, weird inputs, adversarial flows. Break things. |
| **Sprint 3 — Deep dive** | Pick the most interesting finding from Sprints 1-2. Reproduce reliably, document thoroughly. |

No time boxing — move at your own pace. If you finish, pick up another scenario.

## Bug Reporting

Post to the Slack channel using this format:

```text
**Type:** Bug / Paper Cut
**Area:** [Component/Adapter/Flow]
**Severity:** Critical / Major / Minor / Cosmetic
**Summary:** One-line description
**Steps to Reproduce:**
1. ...
2. ...
**Expected:** What should happen
**Actual:** What happened
**Evidence:** [Screenshot/Video]
```

**Key rule: Find and document, don't fix.** Write it down, move on.

## Useful Commands

```bash
# Check all pods
kubectl get pods -n hyperfleet

# API health
curl <API_ENDPOINT>/api/hyperfleet/v1/clusters | jq '.items | length'

# Watch adapter logs
kubectl logs -f deploy/adapter1 -n hyperfleet

# Watch sentinel logs
kubectl logs -f deploy/clusters -n hyperfleet

# RabbitMQ queue status
kubectl port-forward svc/rabbitmq 15672:15672 -n hyperfleet
# Open http://localhost:15672 (guest/guest)

# Grafana dashboards
kubectl port-forward svc/monitoring-grafana 3000:80 -n monitoring
# Open http://localhost:3000 (admin/ignition)
```

## Architecture Docs

- [Adapter Framework](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/components/adapter/framework/adapter-frame-design.md)
- [Sentinel](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/components/sentinel/sentinel.md)
- [API](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/api/)
- [System Overview](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/)
