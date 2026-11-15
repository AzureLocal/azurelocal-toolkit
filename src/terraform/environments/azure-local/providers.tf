# =============================================================================
# Azure Local Environment — Providers
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = var.purge_soft_delete_on_destroy
    }
    resource_group {
      prevent_deletion_if_contains_resources = var.prevent_deletion_if_contains_resources
    }
  }

  subscription_id = var.azure_local_subscription_id
}

provider "azuread" {}
