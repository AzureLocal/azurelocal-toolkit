# =============================================================================
# Landing Zone Module — Outputs
# =============================================================================

output "management_group_ids" {
  description = "Map of management group names to IDs."
  value = {
    root          = azurerm_management_group.root.id
    platform      = azurerm_management_group.platform.id
    identity      = azurerm_management_group.identity.id
    connectivity  = azurerm_management_group.connectivity.id
    management    = azurerm_management_group.management.id
    security      = azurerm_management_group.security.id
    landing_zones = azurerm_management_group.landing_zones.id
  }
}

output "resource_group_ids" {
  description = "Map of resource group key to resource group ID."
  value       = { for k, rg in azurerm_resource_group.groups : k => rg.id }
}

output "resource_group_names" {
  description = "Map of resource group key to resource group name."
  value       = { for k, rg in azurerm_resource_group.groups : k => rg.name }
}
