# =============================================================================
# Monitoring Module — Outputs
# =============================================================================

output "workspace_id" {
  description = "Log Analytics workspace resource ID."
  value       = azurerm_log_analytics_workspace.main.id
}

output "workspace_name" {
  description = "Log Analytics workspace name."
  value       = azurerm_log_analytics_workspace.main.name
}

output "workspace_customer_id" {
  description = "Log Analytics workspace customer (workspace) ID."
  value       = azurerm_log_analytics_workspace.main.workspace_id
}

output "workspace_primary_key" {
  description = "Log Analytics workspace primary shared key."
  value       = azurerm_log_analytics_workspace.main.primary_shared_key
  sensitive   = true
}

output "action_group_id" {
  description = "Critical action group resource ID."
  value       = azurerm_monitor_action_group.critical.id
}
