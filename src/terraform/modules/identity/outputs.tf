# =============================================================================
# Identity Module — Outputs
# =============================================================================

output "key_vault_id" {
  description = "Platform Key Vault resource ID."
  value       = azurerm_key_vault.platform.id
}

output "key_vault_uri" {
  description = "Platform Key Vault URI."
  value       = azurerm_key_vault.platform.vault_uri
}

output "key_vault_name" {
  description = "Platform Key Vault name."
  value       = azurerm_key_vault.platform.name
}

output "azl_key_vault_id" {
  description = "Azure Local Key Vault resource ID."
  value       = var.azl_key_vault_name != "" ? azurerm_key_vault.azure_local[0].id : ""
}

output "managed_identity_ids" {
  description = "Map of managed identity key to principal ID."
  value       = { for k, mi in azurerm_user_assigned_identity.identities : k => mi.principal_id }
}

output "managed_identity_client_ids" {
  description = "Map of managed identity key to client ID."
  value       = { for k, mi in azurerm_user_assigned_identity.identities : k => mi.client_id }
}
