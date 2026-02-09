# =============================================================================
# Maestro Namespace
# =============================================================================

resource "kubernetes_namespace" "maestro" {
  metadata {
    name = var.namespace

    labels = merge(var.labels, {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = "maestro"
    })
  }
}

# =============================================================================
# Helm Dependencies Update
# =============================================================================
# Requires helm-git plugin: helm plugin install https://github.com/aslafy-z/helm-git
# Uses external data source to run during plan phase, ensuring dependencies
# exist before helm_release validates the chart.

data "external" "helm_dependency_update" {
  program = ["bash", "-c", <<-EOF
    helm dependency update ${path.module}/charts/maestro-stack >&2
    echo '{"status": "ok"}'
  EOF
  ]
}

# =============================================================================
# Maestro Stack Helm Release
# =============================================================================

resource "helm_release" "maestro_stack" {
  name      = "maestro"
  chart     = "${path.module}/charts/maestro-stack"
  namespace = kubernetes_namespace.maestro.metadata[0].name

  values = [
    yamlencode({
      # Maestro Server configuration (via 'server' alias)
      server = {
        replicas = var.server_replicas

        serviceAccount = {
          name = "maestro-server"
        }

        database = {
          secretName = var.enable_postgres ? "maestro-db" : "maestro-rds"
          sslMode    = "disable"
        }

        messageBroker = {
          type       = "mqtt"
          secretName = "maestro-mqtt"
          mqtt = {
            host = "maestro-mqtt"
            port = 1883
            topics = {
              sourceEvents = "sources/maestro/consumers/+/sourceevents"
              agentEvents  = "sources/maestro/consumers/+/agentevents"
            }
          }
        }

        # Deploy embedded PostgreSQL for demo
        postgresql = {
          enabled = var.enable_postgres
          database = {
            name     = "maestro"
            user     = "maestro"
            password = "maestro-password"
            host     = "maestro-db"
          }
          service = {
            name = "maestro-db"
            port = 5432
          }
          secretName = "maestro-db"
        }

        # Deploy embedded Mosquitto MQTT broker for demo
        mosquitto = {
          enabled = var.enable_mqtt_broker
          service = {
            name = "maestro-mqtt"
            port = 1883
          }
        }

        resources = {
          requests = {
            cpu    = "100m"
            memory = "256Mi"
          }
          limits = {
            cpu    = "500m"
            memory = "512Mi"
          }
        }

        logging = {
          klogV = "4"
        }
      }

      # Maestro Agent configuration (via 'agent' alias)
      agent = {
        enabled     = true
        environment = "production"

        consumerName        = var.consumer_name
        cloudeventsClientId = "${var.consumer_name}-work-agent"

        serviceAccount = {
          name = "maestro-agent"
        }

        messageBroker = {
          type = "mqtt"
          mqtt = {
            host = "maestro-mqtt.${var.namespace}"
            port = "1883"
          }
        }

        installWorkCRDs = true

        logging = {
          klogV = "4"
        }
      }
    })
  ]

  depends_on = [
    kubernetes_namespace.maestro,
    data.external.helm_dependency_update
  ]

  timeout = 600
}
