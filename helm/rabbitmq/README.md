# RabbitMQ Helm Chart

Simple RabbitMQ chart for HyperFleet development environments.

**⚠️ WARNING: This is NOT production-ready!**

This chart uses:
- A Deployment (not StatefulSet)
- No persistent storage
- Hardcoded credentials in values
- Single replica only

For production, use the [official Bitnami RabbitMQ chart](https://github.com/bitnami/charts/tree/main/bitnami/rabbitmq).

## Installation

```bash
# Install with default values
helm install rabbitmq ./helm/rabbitmq --namespace hyperfleet --create-namespace

# Install with custom values
helm install rabbitmq ./helm/rabbitmq \
  --namespace hyperfleet \
  --set auth.username=myuser \
  --set auth.password=mypassword
```

## Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `image.repository` | RabbitMQ image repository | `rabbitmq` |
| `image.tag` | RabbitMQ image tag | `3.13-management-alpine` |
| `image.pullPolicy` | Image pull policy | `IfNotPresent` |
| `replicaCount` | Number of replicas | `1` |
| `auth.username` | RabbitMQ username | `guest` |
| `auth.password` | RabbitMQ password | `guest` |
| `service.type` | Kubernetes service type | `ClusterIP` |
| `service.amqpPort` | AMQP port | `5672` |
| `service.managementPort` | Management UI port | `15672` |
| `resources.requests.cpu` | CPU request | `100m` |
| `resources.requests.memory` | Memory request | `256Mi` |
| `resources.limits.cpu` | CPU limit | `500m` |
| `resources.limits.memory` | Memory limit | `512Mi` |

## Accessing RabbitMQ

### AMQP Protocol

```bash
# Port-forward AMQP
kubectl port-forward -n hyperfleet svc/rabbitmq 5672:5672
```

Connection URL: `amqp://guest:guest@localhost:5672`

### Management UI

```bash
# Port-forward Management UI
kubectl port-forward -n hyperfleet svc/rabbitmq 15672:15672
```

Open: http://localhost:15672

Login: `guest` / `guest`

## Uninstallation

```bash
helm uninstall rabbitmq --namespace hyperfleet
```
