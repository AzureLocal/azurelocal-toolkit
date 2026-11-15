# =============================================================================
# Terraform Backend Bootstrap
# =============================================================================
# Purpose: Provisions the Azure Storage Account used for Terraform remote state.
# Run this ONCE before any other Terraform operations.
#
# Every value comes from devops.state, azure and tags of infrastructure.yml
# (terraform/backend/terraform.tfvars.json, written by New-IacVariableFiles.ps1):
#   terraform init
#   terraform plan -var-file=terraform.tfvars.json -out=tfplan
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
  name     = var.resource_group_name
  location = var.location

  # state_tags are settings of this code (class c in the registry); tags come from the tags section of the file.
  tags = merge(var.tags, var.state_tags)
}

# -----------------------------------------------------------------------------
# Storage Account for Terraform State
# -----------------------------------------------------------------------------
resource "azurerm_storage_account" "tfstate" {
  name                          = var.storage_account_name
  resource_group_name           = azurerm_resource_group.tfstate.name
  location                      = azurerm_resource_group.tfstate.location
  account_tier                  = var.account_tier
  account_replication_type      = var.replication_type
  public_network_access_enabled = var.public_network_access_enabled
  # TLS 1.2 is the minimum version Azure Storage supports from 3 February 2026 (Microsoft Learn: Enforce a minimum required version of
  # Transport Layer Security (TLS) for requests to a storage account, https://learn.microsoft.com/azure/storage/common/transport-layer-security-configure-minimum-version).
  min_tls_version = "TLS1_2"

  blob_properties {
    versioning_enabled = var.versioning_enabled

    delete_retention_policy {
      days = var.blob_soft_delete_retention_days
    }

    container_delete_retention_policy {
      days = var.container_soft_delete_retention_days
    }
  }

  tags = azurerm_resource_group.tfstate.tags
}

# -----------------------------------------------------------------------------
# Storage Container for State Files
# -----------------------------------------------------------------------------
resource "azurerm_storage_container" "tfstate" {
  name               = var.container_name
  storage_account_id = azurerm_storage_account.tfstate.id
  # The state holds names, IDs and generated passwords: the container is never readable without sign-in.
  container_access_type = "private"
}

# -----------------------------------------------------------------------------
# Storage Account Network Rules: everything not listed is denied
# -----------------------------------------------------------------------------
resource "azurerm_storage_account_network_rules" "tfstate" {
  storage_account_id = azurerm_storage_account.tfstate.id
  default_action     = "Deny"
  bypass             = var.network_bypass
  ip_rules           = var.allowed_ip_ranges

  lifecycle {
    # IP rules apply to public network access only: with public access off they would be dead (Microsoft Learn: Configure Azure
    # Storage firewalls and virtual networks, https://learn.microsoft.com/azure/storage/common/storage-network-security).
    precondition {
      condition     = length(var.allowed_ip_ranges) == 0 || var.public_network_access_enabled
      error_message = "devops.state.allowed_ip_ranges needs devops.state.public_network_access = true: IP rules apply to public network access only."
    }
  }
}
