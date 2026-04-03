# =============================================================================
# Compute Module — Outputs
# =============================================================================

output "vm_ids" {
  description = "Map of VM key to VM resource ID."
  value       = { for k, vm in azurerm_windows_virtual_machine.vms : k => vm.id }
}

output "vm_private_ips" {
  description = "Map of VM key to private IP address."
  value       = { for k, nic in azurerm_network_interface.vm_nics : k => nic.private_ip_address }
}

output "vm_identity_principal_ids" {
  description = "Map of VM key to system-assigned managed identity principal ID."
  value       = { for k, vm in azurerm_windows_virtual_machine.vms : k => vm.identity[0].principal_id }
}
