# =============================================================================
# Automatically Generate Helm Values Files
# =============================================================================
# These local_file resources write YAML files to ../generated-values-from-terraform/
# every time terraform apply runs (when use_pubsub=true).

locals {
  helm_values_dir = "${path.module}/../generated-values-from-terraform"

  # Build adapter values map
  adapter_values = var.use_pubsub ? {
    for sub_key, sub_data in module.pubsub[0].pubsub_config.subscriptions : sub_data.adapter_name => {
      broker = {
        type = "googlepubsub"
        googlepubsub = {
          projectId      = var.gcp_project_id
          subscriptionId = sub_data.subscription_name
          topic          = sub_data.topic_name
        }
      }
    }
  } : {}

  # Build sentinel values map
  sentinel_values = var.use_pubsub ? {
    for topic_name, topic_data in module.pubsub[0].pubsub_config.topics : topic_name => {
      broker = {
        type  = "googlepubsub"
        topic = topic_data.topic_name
        googlepubsub = {
          projectId = var.gcp_project_id
        }
      }
    }
  } : {}
}

# Write adapter YAML files
resource "local_file" "adapter_values" {
  for_each = local.adapter_values

  filename = "${local.helm_values_dir}/${each.key}.yaml"
  content  = yamlencode(each.value)

  file_permission = "0644"
}

# Write sentinel YAML files
resource "local_file" "sentinel_values" {
  for_each = local.sentinel_values

  filename = "${local.helm_values_dir}/sentinel-${each.key}.yaml"
  content  = yamlencode(each.value)

  file_permission = "0644"
}

# Write OIDC env file — consumed by the Makefile (included before env.gcp) for
# edge human authentication and API-mode Kubernetes ServiceAccount validation.
resource "local_file" "oidc_env" {
  count = var.cloud_provider == "gke" ? 1 : 0

  filename        = "${local.helm_values_dir}/oidc.env"
  file_permission = "0644"
  content         = <<-EOT
    OIDC_ISSUER_URL ?= ${module.gke_cluster[0].oidc_issuer_url}
    OIDC_JWKS_URL ?= ${module.gke_cluster[0].oidc_issuer_url}/jwks
    KUBERNETES_OIDC_ISSUER_URL ?= ${module.gke_cluster[0].oidc_issuer_url}
    KUBERNETES_OIDC_JWKS_URL ?= ${module.gke_cluster[0].oidc_issuer_url}/jwks
  EOT
}
