output "network_name" {
  description = "Name of the VPC network"
  value       = google_compute_network.dev_vpc.name
}

output "network_id" {
  description = "ID of the VPC network"
  value       = google_compute_network.dev_vpc.id
}

output "subnet_name" {
  description = "Name of the subnet"
  value       = google_compute_subnetwork.dev_subnet.name
}

output "subnet_id" {
  description = "ID of the subnet"
  value       = google_compute_subnetwork.dev_subnet.id
}

output "region" {
  description = "Region of the subnet"
  value       = google_compute_subnetwork.dev_subnet.region
}

output "pods_range_name" {
  description = "Name of the secondary range for pods"
  value       = "pods"
}

output "services_range_name" {
  description = "Name of the secondary range for services"
  value       = "services"
}

# Helper output for developers
output "developer_config" {
  description = "Values to use in developer tfvars"
  value       = <<-EOT

    # Add these to your dev-<username>.tfvars:
    gcp_network    = "${google_compute_network.dev_vpc.name}"
    gcp_subnetwork = "${google_compute_subnetwork.dev_subnet.name}"

  EOT
}
