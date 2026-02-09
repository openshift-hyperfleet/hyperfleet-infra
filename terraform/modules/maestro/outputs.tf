output "namespace" {
  description = "Namespace where Maestro is deployed"
  value       = kubernetes_namespace.maestro.metadata[0].name
}

output "release_name" {
  description = "Helm release name"
  value       = helm_release.maestro_stack.name
}

output "release_status" {
  description = "Helm release status"
  value       = helm_release.maestro_stack.status
}
