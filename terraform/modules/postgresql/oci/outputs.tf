output "id" {
  description = "OCID of the db system."
  value       = oci_psql_db_system.this.id
}

output "primary_db_endpoint_private_ip" {
  description = "Private IP of the db system's primary endpoint."
  value       = oci_psql_db_system.this.network_details[0].primary_db_endpoint_private_ip
}
