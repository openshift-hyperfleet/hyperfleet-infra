variable "tenancy_ocid" {
  description = "OCID of the rhelcert tenancy."
  type        = string
}

variable "region" {
  description = "OCI region to create resources in."
  type        = string
  default     = "us-sanjose-1"
}

variable "oci_auth" {
  description = "OCI provider auth mode: \"ApiKey\" (durable) or \"SecurityToken\" (browser SSO session, via `oci session authenticate`)."
  type        = string
  default     = "ApiKey"

  validation {
    condition     = contains(["ApiKey", "SecurityToken"], var.oci_auth)
    error_message = "oci_auth must be \"ApiKey\" or \"SecurityToken\"."
  }
}

variable "oci_config_file_profile" {
  description = "Profile name in ~/.oci/config to use when oci_auth = \"SecurityToken\"."
  type        = string
  default     = "DEFAULT"
}

variable "oci_user_ocid" {
  description = "User OCID, when oci_auth = \"ApiKey\"."
  type        = string
  default     = null
}

variable "oci_fingerprint" {
  description = "API key fingerprint, when oci_auth = \"ApiKey\"."
  type        = string
  default     = null
}

variable "oci_private_key_path" {
  description = "Path to the API private key, when oci_auth = \"ApiKey\"."
  type        = string
  default     = null
}

variable "team_compartment_id" {
  description = <<-EOT
    OCID of the "HyperFleet" team compartment (rhelcert tenancy). This is the
    parent, not one of its existing sub-compartments — hyperfleet-ci is
    created as a sibling of hyperfleet-sandbox/hyperfleet-poc/hyperfleet-demos,
    per team convention: never create resources directly in the team
    compartment, always in a sub-compartment.
  EOT
  type        = string
}

variable "quota_statements" {
  description = <<-EOT
    Quota policy statements. See terraform/modules/quota/oci/variables.tf for
    how to derive the correct compute-core and container-engine values for
    this tenancy before setting this.
  EOT
  type        = list(string)
}

variable "budget_amount" {
  description = "Monthly budget amount (USD) for the hyperfleet-ci compartment."
  type        = number
  default     = 150
}

variable "budget_alert_recipients" {
  description = "Email addresses that receive hyperfleet-ci budget alerts."
  type        = list(string)
}

variable "sweep_function_image" {
  description = <<-EOT
    Tag-form OCIR image reference for the oci-ci-sweep function (e.g.
    "sjc.ocir.io/<namespace>/oci-ci-sweep:<tag>"). OCI Functions requires a tag
    reference here; the immutable pin is set separately in
    sweep_function_image_digest. Push the image first, then set both.
  EOT
  type        = string

  validation {
    condition     = can(regex(":[^/@:]+$", var.sweep_function_image)) && !can(regex("@", var.sweep_function_image))
    error_message = "sweep_function_image must be a tag reference (repo:tag), not a digest reference (repo@sha256:...). The digest goes in sweep_function_image_digest."
  }
}

variable "sweep_function_image_digest" {
  description = <<-EOT
    Immutable @sha256 digest the oci-ci-sweep function is pinned to (e.g.
    "sha256:<64-hex>"). Read it back from OCIR after pushing the tag in
    sweep_function_image. Repository immutability isn't supported by the
    Artifacts API in us-sanjose-1, so this digest — not the tag — is what
    guarantees the deployed function keeps running the exact content reviewed.
  EOT
  type        = string

  validation {
    condition     = can(regex("^sha256:[0-9a-f]{64}$", var.sweep_function_image_digest))
    error_message = "sweep_function_image_digest must be an immutable digest of the form sha256:<64 hex chars>."
  }
}

variable "sweep_run_window_hours" {
  description = <<-EOT
    Age, in hours, past which the sweep deletes a resource. Keep this close
    to how long a normal e2e run actually takes plus a small buffer, not a
    full day: at $7/day per 3-node OKE cluster, a shorter window shrinks how
    much a single leaked/orphaned resource can cost before the sweep catches
    it (the sweep is the backstop for HYPERFLEET-1563's per-run teardown,
    not the primary cleanup path).
  EOT
  type        = number
  default     = 8

  validation {
    condition     = var.sweep_run_window_hours >= 1 && var.sweep_run_window_hours <= 8760 && floor(var.sweep_run_window_hours) == var.sweep_run_window_hours
    error_message = "sweep_run_window_hours must be a whole number between 1 and 8760 (1 year)."
  }
}

variable "sweep_dry_run" {
  description = "When true, the sweep only logs what it would delete. Flip to false once verified end to end."
  type        = bool
  default     = true
}

variable "sweep_schedule_recurrence" {
  description = "Cron expression for how often the sweep runs."
  type        = string
  default     = "0 * * * *"
}

# OCI Database with PostgreSQL — scaffolding for the Oracle deployment path's
# managed instance (see architecture repo ADR 0022:
# https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/adrs/0022-oci-managed-postgresql.md).
# Disabled by default: not yet wired into any real deployment, and must never
# be pointed at the hyperfleet-ci compartment (its sweep deletes DB systems).

variable "postgresql_enabled" {
  description = <<-EOT
    Whether to create the managed OCI Database with PostgreSQL instance for
    the Oracle deployment path. Disabled by default — this is scaffolding
    (see architecture ADR 0022), not yet wired into a real deployment.
  EOT
  type        = bool
  default     = false
}

variable "postgresql_compartment_id" {
  description = <<-EOT
    OCID of the compartment for the managed db system. Must not be
    hyperfleet-ci (its sweep function deletes DB systems older than its run
    window) — enforced by a lifecycle precondition in the postgresql module,
    not just this description. No default: required once postgresql_enabled
    is true.
  EOT
  type        = string
  default     = null

  validation {
    condition     = !var.postgresql_enabled || var.postgresql_compartment_id != null
    error_message = "postgresql_compartment_id is required when postgresql_enabled is true."
  }
}

variable "postgresql_subnet_id" {
  description = <<-EOT
    OCID of the subnet for the db system's private endpoint (OCI Database
    with PostgreSQL has no public-endpoint option). No default: required
    once postgresql_enabled is true.
  EOT
  type        = string
  default     = null

  validation {
    condition     = !var.postgresql_enabled || var.postgresql_subnet_id != null
    error_message = "postgresql_subnet_id is required when postgresql_enabled is true."
  }
}

variable "postgresql_display_name" {
  description = "Display name for the managed db system."
  type        = string
  default     = "hyperfleet-managed-postgresql"
}

variable "postgresql_db_version" {
  description = "PostgreSQL major version. See architecture ADR 0022 for why 17 was chosen."
  type        = string
  default     = "17"
}

variable "postgresql_shape" {
  description = "Compute shape for the db system's instance node. See architecture ADR 0022 for why VM.Standard.E5.Flex was chosen."
  type        = string
  default     = "VM.Standard.E5.Flex"
}

variable "postgresql_instance_ocpu_count" {
  description = "OCPU count per db system instance node."
  type        = number
  default     = 2
}

variable "postgresql_instance_memory_size_in_gbs" {
  description = "Memory, in GB, per db system instance node."
  type        = number
  default     = 32
}

variable "postgresql_availability_domain" {
  description = <<-EOT
    Availability domain the db system's storage is pinned to, when
    postgresql_storage_is_regionally_durable is false. Null (the default)
    derives it from the region var is set to — us-sanjose-1 has only one AD,
    so regional (multi-AD) storage durability isn't available there, see
    architecture ADR 0022. Set explicitly only to pin a specific AD in a
    multi-AD region.
  EOT
  type        = string
  default     = null
}

variable "postgresql_storage_is_regionally_durable" {
  description = <<-EOT
    Whether db system storage is durable across multiple availability
    domains. Must stay false in us-sanjose-1 (single AD) — see decision
    record 0001.
  EOT
  type        = bool
  default     = false
}

variable "postgresql_admin_username" {
  description = "Admin username for the managed db system. Gets oci_admin_role, not PostgreSQL SUPERUSER — see architecture ADR 0022."
  type        = string
  default     = "hyperfleet_admin"
}

variable "postgresql_admin_password_secret_id" {
  description = <<-EOT
    OCID of the Vault secret holding the admin password. No default:
    required once postgresql_enabled is true — plaintext passwords are
    deliberately not supported.
  EOT
  type        = string
  default     = null

  validation {
    condition     = !var.postgresql_enabled || var.postgresql_admin_password_secret_id != null
    error_message = "postgresql_admin_password_secret_id is required when postgresql_enabled is true."
  }
}
