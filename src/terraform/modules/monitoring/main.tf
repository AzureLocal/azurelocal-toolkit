# =============================================================================
# Monitoring Module — Log Analytics, Diagnostic Settings, Alerts
# =============================================================================
# Mirrors: Implementation Part 2, Phase 4 (Stage 06) — Log Analytics
#          Implementation Part 5, Phase 2 (Stage 18) — Monitoring
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
# Log Analytics Solutions — for Azure Local monitoring
# -----------------------------------------------------------------------------
resource "azurerm_log_analytics_solution" "updates" {
  solution_name         = "Updates"
  workspace_resource_id = azurerm_log_analytics_workspace.main.id
  workspace_name        = azurerm_log_analytics_workspace.main.name
  location              = var.location
  resource_group_name   = var.resource_group_name

  plan {
    publisher = "Microsoft"
    product   = "OMSGallery/Updates"
  }
}

resource "azurerm_log_analytics_solution" "security" {
  solution_name         = "Security"
  workspace_resource_id = azurerm_log_analytics_workspace.main.id
  workspace_name        = azurerm_log_analytics_workspace.main.name
  location              = var.location
  resource_group_name   = var.resource_group_name

  plan {
    publisher = "Microsoft"
    product   = "OMSGallery/Security"
  }
}

# -----------------------------------------------------------------------------
# Action Groups — notification targets for alerts
# -----------------------------------------------------------------------------
resource "azurerm_monitor_action_group" "critical" {
  name                = "ag-${var.org_code}-critical"
  resource_group_name = var.resource_group_name
  short_name          = "Critical"
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

# -----------------------------------------------------------------------------
# Alert Rules — Azure Local cluster health
# -----------------------------------------------------------------------------
resource "azurerm_monitor_metric_alert" "cluster_health" {
  count = var.enable_cluster_alerts ? 1 : 0

  name                = "alert-${var.org_code}-cluster-health"
  resource_group_name = var.resource_group_name
  scopes              = var.alert_scopes
  description         = "Alert when Azure Local cluster health degrades."
  severity            = 1
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.AzureStackHCI/clusters"
    metric_name      = "HealthStatus"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 1
  }

  action {
    action_group_id = azurerm_monitor_action_group.critical.id
  }

  tags = var.tags
}
