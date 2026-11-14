# =============================================================================
# Monitoring Module — Log Analytics workspace and action group
# =============================================================================
# Azure Monitor work in this toolkit is the Log Analytics workspace, the data
# collection endpoint, the Azure Monitor Agent extension and the Azure Local
# Insights rule association (see scripts/deploy/05-operational-foundations).
# This module creates the workspace and the action group of the notification
# addresses. It creates no alert rule, no data collection endpoint and no
# data collection rule.
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
# Log Analytics Workspace
# -----------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "main" {
  name                = var.workspace_name
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = var.sku
  retention_in_days   = var.retention_days
  tags                = var.tags
}

# -----------------------------------------------------------------------------
# Action Group — notification targets
# -----------------------------------------------------------------------------
resource "azurerm_monitor_action_group" "critical" {
  name                = var.action_group_name
  resource_group_name = var.resource_group_name
  # Same rule as Deploy-ActionGroup.ps1: the letters and digits of the name, at most 12 characters (the Azure limit of an action group
  # short name), so the Terraform route and the script route make the same group.
  short_name          = substr(replace(var.action_group_name, "/[^A-Za-z0-9]/", ""), 0, 12)
  enabled             = true

  dynamic "email_receiver" {
    for_each = var.alert_email_addresses
    content {
      name          = "email-${email_receiver.key}"
      email_address = email_receiver.value
    }
  }

  tags = var.tags
}
