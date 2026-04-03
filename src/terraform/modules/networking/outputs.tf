# =============================================================================
# Networking Module — Outputs
# =============================================================================

output "vnet_id" {
  description = "ID of the hub virtual network."
  value       = azurerm_virtual_network.hub.id
}

output "vnet_name" {
  description = "Name of the hub virtual network."
  value       = azurerm_virtual_network.hub.name
}

output "subnet_ids" {
  description = "Map of subnet key to subnet ID."
  value       = { for k, s in azurerm_subnet.subnets : k => s.id }
}

output "nsg_ids" {
  description = "Map of NSG name to NSG ID."
  value       = { for k, nsg in azurerm_network_security_group.nsgs : k => nsg.id }
}

output "vpn_gateway_id" {
  description = "VPN Gateway ID (empty if not deployed)."
  value       = var.enable_vpn_gateway ? azurerm_virtual_network_gateway.vpn[0].id : ""
}

output "vpn_gateway_public_ip" {
  description = "VPN Gateway public IP (empty if not deployed)."
  value       = var.enable_vpn_gateway ? azurerm_public_ip.vpn[0].ip_address : ""
}

output "bastion_public_ip" {
  description = "Bastion host public IP (empty if not deployed)."
  value       = var.enable_bastion ? azurerm_public_ip.bastion[0].ip_address : ""
}

output "nat_gateway_id" {
  description = "NAT Gateway ID (empty if not deployed)."
  value       = var.enable_nat_gateway ? azurerm_nat_gateway.main[0].id : ""
}
