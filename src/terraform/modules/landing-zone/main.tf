# =============================================================================
# Landing Zone Module — Management Groups & Resource Groups
# =============================================================================
# Mirrors: Implementation Part 2, Phase 1 (Stage 03)
# Creates the Azure management group hierarchy and resource groups.
# =============================================================================

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

# -----------------------------------------------------------------------------
# Management Group Hierarchy
# Uses Azure Verified Module for management group patterns
# -----------------------------------------------------------------------------
resource "azurerm_management_group" "root" {
  display_name               = var.management_groups.root_display_name
  name                       = var.management_groups.root_name
  parent_management_group_id = var.management_groups.parent_id
}

resource "azurerm_management_group" "platform" {
  display_name               = var.management_groups.platform_display_name
  name                       = var.management_groups.platform_name
  parent_management_group_id = azurerm_management_group.root.id
}

resource "azurerm_management_group" "identity" {
  display_name               = "Identity"
  name                       = var.management_groups.identity_name
  parent_management_group_id = azurerm_management_group.platform.id
}

resource "azurerm_management_group" "connectivity" {
  display_name               = "Connectivity"
  name                       = var.management_groups.connectivity_name
  parent_management_group_id = azurerm_management_group.platform.id
}

resource "azurerm_management_group" "management" {
  display_name               = "Management"
  name                       = var.management_groups.management_name
  parent_management_group_id = azurerm_management_group.platform.id
}

resource "azurerm_management_group" "security" {
  display_name               = "Security"
  name                       = var.management_groups.security_name
  parent_management_group_id = azurerm_management_group.platform.id
}

resource "azurerm_management_group" "landing_zones" {
  display_name               = "Landing Zones"
  name                       = var.management_groups.landing_zones_name
  parent_management_group_id = azurerm_management_group.root.id
}

# -----------------------------------------------------------------------------
# Subscription to Management Group Associations
# -----------------------------------------------------------------------------
resource "azurerm_management_group_subscription_association" "connectivity" {
  count               = var.subscriptions.connectivity_id != "" ? 1 : 0
  management_group_id = azurerm_management_group.connectivity.id
  subscription_id     = "/subscriptions/${var.subscriptions.connectivity_id}"
}

resource "azurerm_management_group_subscription_association" "identity" {
  count               = var.subscriptions.identity_id != "" ? 1 : 0
  management_group_id = azurerm_management_group.identity.id
  subscription_id     = "/subscriptions/${var.subscriptions.identity_id}"
}

resource "azurerm_management_group_subscription_association" "management" {
  count               = var.subscriptions.management_id != "" ? 1 : 0
  management_group_id = azurerm_management_group.management.id
  subscription_id     = "/subscriptions/${var.subscriptions.management_id}"
}

resource "azurerm_management_group_subscription_association" "security" {
  count               = var.subscriptions.security_id != "" ? 1 : 0
  management_group_id = azurerm_management_group.security.id
  subscription_id     = "/subscriptions/${var.subscriptions.security_id}"
}

resource "azurerm_management_group_subscription_association" "azure_local" {
  count               = var.subscriptions.azure_local_id != "" ? 1 : 0
  management_group_id = azurerm_management_group.landing_zones.id
  subscription_id     = "/subscriptions/${var.subscriptions.azure_local_id}"
}

# -----------------------------------------------------------------------------
# Resource Groups — organized by function
# -----------------------------------------------------------------------------
resource "azurerm_resource_group" "groups" {
  for_each = var.resource_groups

  name     = each.value
  location = var.location
  tags     = var.tags
}
