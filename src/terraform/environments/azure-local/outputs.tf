# =============================================================================
# Azure Local Environment — Outputs
# =============================================================================

# --- Landing Zone ---
output "management_group_ids" {
  description = "Management group hierarchy IDs."
  value       = module.landing_zone.management_group_ids
}

output "resource_group_names" {
  description = "Resource group names by function."
  value       = module.landing_zone.resource_group_names
}

# --- Networking ---
output "vnet_id" {
  description = "Hub VNet resource ID."
  value       = module.networking.vnet_id
}

output "subnet_ids" {
  description = "Subnet IDs by key."
  value       = module.networking.subnet_ids
}

output "vpn_gateway_public_ip" {
  description = "VPN Gateway public IP."
  value       = module.networking.vpn_gateway_public_ip
}

output "bastion_public_ip" {
  description = "Bastion host public IP."
  value       = module.networking.bastion_public_ip
}

# --- Identity ---
output "key_vault_uri" {
  description = "Platform Key Vault URI."
  value       = module.identity.key_vault_uri
}

output "key_vault_id" {
  description = "Platform Key Vault ID."
  value       = module.identity.key_vault_id
}

# --- Monitoring ---
output "log_analytics_workspace_id" {
  description = "Log Analytics workspace resource ID."
  value       = module.monitoring.workspace_id
}

output "log_analytics_workspace_customer_id" {
  description = "Log Analytics workspace customer ID."
  value       = module.monitoring.workspace_customer_id
}

# --- Compute ---
output "vm_private_ips" {
  description = "Management VM private IP addresses."
  value       = module.compute.vm_private_ips
}
