output "ci_compartment_id" {
  description = "OCID of the hyperfleet-ci compartment."
  value       = module.ci_compartment.id
}

output "sweep_container_repository_path" {
  description = "OCIR repository path to push the sweep function's image to."
  value       = module.ci_sweep.container_repository_path
}

output "sweep_function_id" {
  description = "OCID of the deployed sweep function."
  value       = module.ci_sweep.function_id
}

output "postgresql_id" {
  description = "OCID of the managed PostgreSQL db system, if postgresql_enabled is true."
  value       = try(module.managed_postgresql[0].id, null)
}
