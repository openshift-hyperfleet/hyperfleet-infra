# Without this, Terraform assumes the unprefixed `oci_*` resources belong to
# the default `hashicorp/oci` provider, which is a *different* provider than the
# `oracle/oci` one the root module configures. The module's resources would then
# run under an unconfigured provider and fall back to the ambient auth chain
# (~/.oci/config DEFAULT profile) instead of the root's provider block.
terraform {
  required_providers {
    oci = {
      source = "oracle/oci"
    }
  }
}
