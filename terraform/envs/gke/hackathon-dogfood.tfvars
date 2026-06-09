# HyperFleet Ignition Day — Cluster 1: "Dog Food"
# Scenarios 1 (Fresh Eyes), 2 (Reconciliation Loop), 3 (Something Is Wrong)
# Two deployments on this cluster: hyperfleet-healthy + hyperfleet-broken

developer_name    = "hackathon-dogfood"
kubernetes_suffix = "default"

cloud_provider = "gke"

gcp_project_id = "hcm-hyperfleet"
gcp_region     = "us-central1"
gcp_zone       = "us-central1-a"
gcp_network    = "hyperfleet-dev-vpc"
gcp_subnetwork = "hyperfleet-dev-vpc-subnet"

node_count   = 2
machine_type = "e2-standard-4"
use_spot_vms = true

enable_deletion_protection = false

# RabbitMQ — no Pub/Sub needed for hackathon
use_pubsub = false

# External API access for participants
enable_external_api = true
