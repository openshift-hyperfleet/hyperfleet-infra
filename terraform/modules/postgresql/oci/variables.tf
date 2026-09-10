variable "compartment_id" {
  description = <<-EOT
    OCID of the compartment the managed db system is created in. Do not point
    this at hyperfleet-ci: that compartment's sweep function deletes DB
    systems older than its run window (see
    terraform/modules/lifecycle/oci), which would destroy this instance.
    Enforced at apply time by a lifecycle precondition against
    var.ci_compartment_id, not just by this description.
  EOT
  type        = string
}

variable "ci_compartment_id" {
  description = <<-EOT
    OCID of the hyperfleet-ci compartment, passed in so this module can
    reject compartment_id being set to it (see compartment_id). Null skips
    the check — only set when the caller doesn't have a CI compartment to
    protect against.
  EOT
  type        = string
  default     = null
}

variable "tenancy_ocid" {
  description = <<-EOT
    Tenancy OCID, used to look up the availability domains available in the
    provider's configured region (see availability_domain).
  EOT
  type        = string
}

variable "display_name" {
  description = "Display name for the db system."
  type        = string
  default     = "hyperfleet-managed-postgresql"
}

variable "db_version" {
  description = <<-EOT
    PostgreSQL major version. See architecture repo ADR 0022
    (hyperfleet/adrs/0022-oci-managed-postgresql.md) for why 17 was chosen
    (latest version with an ACTIVE default configuration compatible with the
    flex shape family, confirmed live against the rhelcert tenancy).
  EOT
  type        = string
  default     = "17"
}

variable "shape" {
  description = <<-EOT
    Compute shape for the db system's instance node. VM.Standard.E5.Flex is
    the current-generation flex shape, confirmed available in us-sanjose-1
    (see architecture ADR 0022).
  EOT
  type        = string
  default     = "VM.Standard.E5.Flex"
}

variable "instance_ocpu_count" {
  description = "OCPU count per db system instance node (VM.Standard.E5.Flex supports 1-64)."
  type        = number
  default     = 2
}

variable "instance_memory_size_in_gbs" {
  description = "Memory, in GB, per db system instance node (VM.Standard.E5.Flex supports 16-1024, default 16/OCPU)."
  type        = number
  default     = 32
}

variable "instance_count" {
  description = "Number of db system instance nodes."
  type        = number
  default     = 1
}

variable "availability_domain" {
  description = <<-EOT
    Availability domain the db system's storage is pinned to, when
    storage_is_regionally_durable is false. Null (the default) derives it
    from the provider's configured region instead of hardcoding one: this
    module looks up that region's availability domains and uses the first
    one. Set explicitly only to pin a specific AD in a multi-AD region.
  EOT
  type        = string
  default     = null
}

variable "storage_is_regionally_durable" {
  description = <<-EOT
    Whether db system storage is durable across multiple availability
    domains. Must be false in us-sanjose-1 (single AD, see architecture
    ADR 0022) — the provider rejects is_regionally_durable = true together with
    an explicit availability_domain, and true requires availability_domain
    to be unset, which isn't meaningful with only one AD to place it in.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = var.storage_is_regionally_durable == false || var.availability_domain == null
    error_message = "storage_is_regionally_durable = true requires availability_domain to be unset (regional storage doesn't pin to one AD)."
  }
}

variable "subnet_id" {
  description = <<-EOT
    OCID of the subnet the db system's private endpoint is created in. OCI
    Database with PostgreSQL has no public-endpoint option (see architecture
    ADR 0022) — this subnet must already have routing worked out for
    whatever needs to reach the database. Required when enabling the module.
  EOT
  type        = string
  default     = null
}

variable "nsg_ids" {
  description = "Network security group OCIDs applied to the db system's private endpoint."
  type        = list(string)
  default     = []
}

variable "admin_username" {
  description = "Admin username. Gets oci_admin_role, not PostgreSQL SUPERUSER (see architecture ADR 0022)."
  type        = string
  default     = "hyperfleet_admin"
}

variable "admin_password_secret_id" {
  description = <<-EOT
    OCID of the Vault secret holding the admin password. Passed as
    credentials.password_details.secret_id (password_type = VAULT_SECRET) —
    plaintext passwords are deliberately not supported by this module, to
    avoid an admin credential ever passing through a .tfvars file or
    Terraform state in plaintext. Required when enabling the module.
  EOT
  type        = string
  default     = null
}

variable "backup_retention_days" {
  description = "Number of days daily backups are retained."
  type        = number
  default     = 7
}

variable "backup_start" {
  description = "Daily backup start time, HH:MM in UTC."
  type        = string
  default     = "02:00"
}

variable "freeform_tags" {
  description = "Freeform tags applied to the db system."
  type        = map(string)
  default     = {}
}
