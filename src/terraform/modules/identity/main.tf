# =============================================================================
# Identity Module — Key Vault, RBAC, Managed Identities
# =============================================================================
# Mirrors: Implementation Part 2, Phase 3 (Stage 05) — RBAC & Permissions
#          Implementation Part 2, Phase 4 (Stage 06) — Key Vault
# =============================================================================

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
  }
}

data "azurerm_client_config" "current" {}

# -----------------------------------------------------------------------------
# Key Vault — Platform secrets store
# -----------------------------------------------------------------------------
resource "azurerm_key_vault" "platform" {
  name                       = var.key_vault_name
  location                   = var.location
  resource_group_name        = var.resource_group_name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  purge_protection_enabled   = true
  soft_delete_retention_days = 90

  enable_rbac_authorization = true

  network_acls {
    bypass         = "AzureServices"
    default_action = "Deny"
    ip_rules       = var.key_vault_allowed_ips
  }

  tags = var.tags
}

# Key Vault Diagnostic Settings
resource "azurerm_monitor_diagnostic_setting" "keyvault" {
  count = var.log_analytics_workspace_id != "" ? 1 : 0

  name                       = "diag-${var.key_vault_name}"
  target_resource_id         = azurerm_key_vault.platform.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "AuditEvent"
  }

  metric {
    category = "AllMetrics"
  }
}

# -----------------------------------------------------------------------------
# Azure Local Key Vault — cluster-specific secrets
# -----------------------------------------------------------------------------
resource "azurerm_key_vault" "azure_local" {
  count = var.azl_key_vault_name != "" ? 1 : 0

  name                       = var.azl_key_vault_name
  location                   = var.location
  resource_group_name        = var.azl_key_vault_resource_group
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  purge_protection_enabled   = true
  soft_delete_retention_days = 90

  enable_rbac_authorization = true

  network_acls {
    bypass         = "AzureServices"
    default_action = "Deny"
    ip_rules       = var.key_vault_allowed_ips
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Deployment Service Principal — RBAC Role Assignments
# Mirrors: Implementation Part 2, Phase 3 — sp-azurelocal-deploy
# -----------------------------------------------------------------------------

# Subscription-level roles
resource "azurerm_role_assignment" "spn_subscription" {
  for_each = toset(var.spn_subscription_roles)

  scope                = "/subscriptions/${var.azure_local_subscription_id}"
  role_definition_name = each.value
  principal_id         = var.deployment_spn_object_id
}

# Resource-group-level roles
locals {
  rg_role_assignments = flatten([
    for rg_key, rg_name in var.spn_resource_group_roles : [
      for role in rg_name.roles : {
        key       = "${rg_key}-${role}"
        scope     = rg_name.scope
        role_name = role
      }
    ]
  ])
}

resource "azurerm_role_assignment" "spn_resource_group" {
  for_each = { for ra in local.rg_role_assignments : ra.key => ra }

  scope                = each.value.scope
  role_definition_name = each.value.role_name
  principal_id         = var.deployment_spn_object_id
}

# Key Vault RBAC for deployment SPN
resource "azurerm_role_assignment" "spn_keyvault" {
  for_each = toset([
    "Key Vault Data Access Administrator",
    "Key Vault Secrets Officer",
    "Key Vault Contributor"
  ])

  scope                = azurerm_key_vault.platform.id
  role_definition_name = each.value
  principal_id         = var.deployment_spn_object_id
}

# -----------------------------------------------------------------------------
# User-Assigned Managed Identities
# -----------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "identities" {
  for_each = var.managed_identities

  name                = each.value.name
  location            = var.location
  resource_group_name = each.value.resource_group
  tags                = var.tags
}
