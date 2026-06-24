provider "google" {
  project = var.project_id
  region  = var.region
}

# =============================================================================
# VPC Network
# =============================================================================
resource "google_compute_network" "dev_vpc" {
  name                    = var.network_name
  auto_create_subnetworks = false
  project                 = var.project_id
}

# =============================================================================
# Subnet with secondary ranges for GKE
# =============================================================================
resource "google_compute_subnetwork" "dev_subnet" {
  name          = "${var.network_name}-subnet"
  ip_cidr_range = var.subnet_cidr
  region        = var.region
  network       = google_compute_network.dev_vpc.id
  project       = var.project_id

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }
}

# =============================================================================
# Firewall Rules
# =============================================================================

# Allow internal communication within the VPC
resource "google_compute_firewall" "allow_internal" {
  name    = "${var.network_name}-allow-internal"
  network = google_compute_network.dev_vpc.name
  project = var.project_id

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "icmp"
  }

  source_ranges = [
    var.subnet_cidr,
    var.pods_cidr,
    var.services_cidr,
  ]
}

# Allow SSH from IAP (Identity-Aware Proxy) for secure access
resource "google_compute_firewall" "allow_iap_ssh" {
  name    = "${var.network_name}-allow-iap-ssh"
  network = google_compute_network.dev_vpc.name
  project = var.project_id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # IAP's IP range
  source_ranges = ["35.235.240.0/20"]
}

# =============================================================================
# Cloud Router & NAT (for private nodes to access internet)
# =============================================================================
resource "google_compute_router" "router" {
  name    = "${var.network_name}-router"
  region  = var.region
  network = google_compute_network.dev_vpc.id
  project = var.project_id
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.network_name}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  project                            = var.project_id
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = false
    filter = "ERRORS_ONLY"
  }
}

# =============================================================================
# Lifecycle Enforcer (Cloud Function + Cloud Scheduler)
# =============================================================================
module "lifecycle_enforcer" {
  source = "../modules/lifecycle"

  project_id = var.project_id
  region     = var.region
  schedule   = var.lifecycle_enforcer_schedule
  dry_run    = var.lifecycle_enforcer_dry_run
  source_dir = "${path.module}/../../functions/lifecycle-enforcer"

  labels = {
    managed-by = "terraform"
    project    = "hyperfleet"
  }
}
