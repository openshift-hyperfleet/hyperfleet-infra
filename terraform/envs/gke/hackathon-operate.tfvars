# HyperFleet Ignition Day — Cluster 3: "Operate"
# Scenario 5 (Shard the Sentinel)
# Pre-seeded clusters with region labels, participants deploy custom sentinels

developer_name    = "hackathon-operate"
kubernetes_suffix = "default"

cloud_provider = "gke"

gcp_project_id = "hcm-hyperfleet"
gcp_region     = "us-central1"
gcp_zone       = "us-central1-a"
gcp_network    = "hyperfleet-dev-vpc"
gcp_subnetwork = "hyperfleet-dev-vpc-subnet"

node_count   = 2
machine_type = "e2-standard-4"
use_spot_vms = false

enable_deletion_protection = false

# RabbitMQ — no Pub/Sub needed for hackathon
use_pubsub = false

# External API access for participants
enable_external_api = true
