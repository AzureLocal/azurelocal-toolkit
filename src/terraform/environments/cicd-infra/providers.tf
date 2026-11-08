# =============================================================================
# CI/CD infrastructure - providers
# =============================================================================
# Sign-in is by environment, never by variable:
#   workstation        az login                     (the provider uses the CLI session)
#   GitHub / GitLab    ARM_USE_OIDC=true plus ARM_CLIENT_ID, ARM_TENANT_ID (federated credential)
#   Azure DevOps       a service connection with workload identity federation
#   a runner VM        ARM_USE_MSI=true plus ARM_CLIENT_ID (the runner's managed identity)
# =============================================================================

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# The subscription that holds the runners (the DevOps subscription).
provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }

  subscription_id     = var.subscription_id
  tenant_id           = var.tenant_id
  storage_use_azuread = true
}

# The subscription that holds the hub VNet (the connectivity subscription). Only used for the hub half of the peering.
provider "azurerm" {
  alias = "hub"

  features {}

  subscription_id     = coalesce(var.hub_subscription_id, var.subscription_id)
  tenant_id           = var.tenant_id
  storage_use_azuread = true
}
