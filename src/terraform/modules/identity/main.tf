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

locals {
  # The vaults hold secrets only, so the standard SKU is enough: premium adds keys protected by a hardware security module
  # (Microsoft Learn: Azure Key Vault service tiers). Not a choice of a deployment.
  key_vault_sku = "standard"

  # Purge protection of the platform vault, the rule of Deploy-KeyVaults.ps1 (phase 04, task 10): it cannot be switched off once it is on,
  # and it keeps a deleted vault's name reserved for the retention period (Microsoft Learn: Azure Key Vault soft-delete overview, Purge
  # protection). So it is on, except when scenario.environment_class (var.environment_class) is lab, test or dev, where a vault has to be
  # removable. The three classes are values of the scenario.environment_class enum of the registry.
  removable_environment_classes     = ["lab", "test", "dev"]
  platform_purge_protection_enabled = !contains(local.removable_environment_classes, lower(trimspace(var.environment_class)))

  # The cluster vault (it stands in for cluster.key_vault) is created the way Microsoft's deployment template creates it: the template's
  # Microsoft.KeyVault/vaults resource takes softDeleteRetentionInDays from the parameter softDeleteRetentionDays and does not set
  # enablePurgeProtection, so purge protection stays off. Microsoft Learn: "Deploy Azure Local via Azure Resource Manager deployment
  # template", ARM template parameters reference (softDeleteRetentionDays, 7 to 90 days; no purge protection parameter),
  # https://learn.microsoft.com/azure/azure-local/deploy/deployment-azure-resource-manager-template; and "Purge protection is an optional
  # Key Vault behavior and is not enabled by default" (Azure Key Vault soft-delete overview,
  # https://learn.microsoft.com/azure/key-vault/general/soft-delete-overview). The template copy: tests/fixtures/arm/microsoft-create-cluster/azuredeploy.json.
  cluster_purge_protection_enabled = false
}

# -----------------------------------------------------------------------------
# Key Vault — Platform secrets store (key_vaults[purpose=management])
# -----------------------------------------------------------------------------
resource "azurerm_key_vault" "platform" {
  name                       = var.key_vault_name
  location                   = var.location
  resource_group_name        = var.resource_group_name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = local.key_vault_sku
  purge_protection_enabled   = local.platform_purge_protection_enabled
  soft_delete_retention_days = var.key_vault_soft_delete_retention_days

  enable_rbac_authorization = var.enable_rbac_authorization

  # With ranges listed (key_vault_allowed_ips) the vault is closed to every other address; without them it keeps the Azure default (all networks).
  dynamic "network_acls" {
    for_each = length(var.key_vault_allowed_ips) > 0 ? [1] : []
    content {
      bypass = var.key_vault_network_bypass
      # The rules exist to close the vault to every address not listed.
      default_action = "Deny"
      ip_rules       = var.key_vault_allowed_ips
    }
  }

  tags = var.tags
}

# Key Vault Diagnostic Settings
resource "azurerm_monitor_diagnostic_setting" "keyvault" {
  # A switch, not a test of the workspace ID: the ID is known only after the workspace exists, so a count on it cannot be planned.
  count = var.diagnostics_enabled ? 1 : 0

  name                       = "${var.diagnostic_setting_name_prefix}${var.key_vault_name}"
  target_resource_id         = azurerm_key_vault.platform.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  dynamic "enabled_log" {
    for_each = toset(var.diagnostic_log_categories)
    content {
      category = enabled_log.value
    }
  }

  dynamic "metric" {
    for_each = toset(var.diagnostic_metric_categories)
    content {
      category = metric.value
    }
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
  sku_name                   = local.key_vault_sku
  purge_protection_enabled   = local.cluster_purge_protection_enabled
  soft_delete_retention_days = var.azl_key_vault_soft_delete_retention_days

  enable_rbac_authorization = var.enable_rbac_authorization

  # No network rules: the cluster Key Vault keeps the Azure default (all networks), because Azure Local needs to reach it
  # (Microsoft Learn: Azure Local system requirements, Key Vault).

  tags = var.tags

  # A cluster vault created by an earlier version of this module has purge protection on, and Azure never turns it off: the
  # provider stops the plan if the value goes from true to false. Ignoring the attribute leaves such a vault as it is, while a
  # new vault is created without purge protection, as Microsoft's template creates it. Remove this rule before managing the
  # attribute on an existing vault on purpose.
  lifecycle {
    ignore_changes = [purge_protection_enabled]
  }
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

# Resource-group-level roles (azure.automation_identity.resource_group_roles[]): each resource group is in the Azure Local subscription.
locals {
  rg_role_assignments = flatten([
    for item in var.spn_resource_group_roles : [
      for role in item.roles : {
        key       = "${item.resource_group}-${role}"
        scope     = "/subscriptions/${var.azure_local_subscription_id}/resourceGroups/${item.resource_group}"
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

# Key Vault RBAC for deployment SPN. These three roles are not a choice of a deployment: Microsoft Learn (Assign required permissions for
# Azure Local deployment) lists them for the identity that deploys, on the resource group of the cluster Key Vault.
locals {
  deployment_key_vault_roles = ["Key Vault Data Access Administrator", "Key Vault Secrets Officer", "Key Vault Contributor"]
}

resource "azurerm_role_assignment" "spn_keyvault" {
  for_each = toset(local.deployment_key_vault_roles)

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
