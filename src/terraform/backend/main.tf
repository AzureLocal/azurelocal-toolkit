# =============================================================================
# Terraform Backend Bootstrap
# =============================================================================
# Purpose: Provisions the Azure Storage Account used for Terraform remote state.
# Run this ONCE before any other Terraform operations.
#
# Usage:
#   terraform init
#   terraform plan -out=tfplan
#   terraform apply tfplan
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

# -----------------------------------------------------------------------------
# Resource Group for Terraform State
# -----------------------------------------------------------------------------
resource "azurerm_resource_group" "tfstate" {
  name     = "rg-${var.org_code}-tfstate-${var.environment}"
  location = var.location

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Purpose     = "Terraform Remote State"
    Owner       = var.owner
    Project     = "Azure Local Toolkit"
  }
}

# -----------------------------------------------------------------------------
# Storage Account for Terraform State
# -----------------------------------------------------------------------------
resource "azurerm_storage_account" "tfstate" {
  name                          = "st${lower(var.org_code)}tfstate${lower(var.environment)}"
  resource_group_name           = azurerm_resource_group.tfstate.name
  location                      = azurerm_resource_group.tfstate.location
  account_tier                  = "Standard"
  account_replication_type      = "GRS"
  public_network_access_enabled = false
  min_tls_version               = "TLS1_2"

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 30
    }

    container_delete_retention_policy {
      days = 30
    }
  }

  tags = azurerm_resource_group.tfstate.tags
}

# -----------------------------------------------------------------------------
# Storage Container for State Files
# -----------------------------------------------------------------------------
resource "azurerm_storage_container" "tfstate" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"
}

# -----------------------------------------------------------------------------
# Storage Account Network Rules — restrict to VNet after bootstrap
# -----------------------------------------------------------------------------
resource "azurerm_storage_account_network_rules" "tfstate" {
  storage_account_id = azurerm_storage_account.tfstate.id
  default_action     = "Deny"
  bypass             = ["AzureServices", "Logging", "Metrics"]
  ip_rules           = var.allowed_ip_ranges
}
