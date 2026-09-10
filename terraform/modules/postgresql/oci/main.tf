# Looks up the availability domains for the provider's configured region
# (data sources are always region-scoped to the provider they run under), so
# availability_domain doesn't have to hardcode one region's AD.
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

resource "oci_psql_db_system" "this" {
  compartment_id = var.compartment_id
  display_name   = var.display_name
  db_version     = var.db_version
  shape          = var.shape

  instance_ocpu_count         = var.instance_ocpu_count
  instance_memory_size_in_gbs = var.instance_memory_size_in_gbs
  instance_count              = var.instance_count

  network_details {
    subnet_id = var.subnet_id
    nsg_ids   = var.nsg_ids
  }

  storage_details {
    system_type           = "OCI_OPTIMIZED_STORAGE"
    is_regionally_durable = var.storage_is_regionally_durable
    availability_domain = var.storage_is_regionally_durable ? null : coalesce(
      var.availability_domain,
      data.oci_identity_availability_domains.ads.availability_domains[0].name,
    )
  }

  credentials {
    username = var.admin_username
    password_details {
      password_type = "VAULT_SECRET"
      secret_id     = var.admin_password_secret_id
    }
  }

  management_policy {
    backup_policy {
      kind           = "DAILY"
      backup_start   = var.backup_start
      retention_days = var.backup_retention_days
    }
  }

  freeform_tags = var.freeform_tags

  lifecycle {
    precondition {
      condition     = var.ci_compartment_id == null || var.compartment_id != var.ci_compartment_id
      error_message = "compartment_id must not be the hyperfleet-ci compartment (var.ci_compartment_id) — its sweep function deletes DB systems older than its run window, which would destroy this db system."
    }
  }
}
