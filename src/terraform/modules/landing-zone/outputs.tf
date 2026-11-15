# =============================================================================
# Landing Zone Module — Outputs
# =============================================================================

output "management_group_ids" {
  description = "Map of management group name to ID."
  value       = local.management_group_ids
}

output "resource_group_ids" {
  description = "Map of resource group key to resource group ID."
  value       = { for k, rg in azurerm_resource_group.groups : k => rg.id }
}

output "resource_group_names" {
  description = "Map of resource group key to resource group name."
  value       = { for k, rg in azurerm_resource_group.groups : k => rg.name }
}
