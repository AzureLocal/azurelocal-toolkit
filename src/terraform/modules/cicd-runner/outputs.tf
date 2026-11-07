# =============================================================================
# cicd-runner module - outputs
# =============================================================================

output "runner_names" {
  description = "VM names (VM mode) or the scale set name. The runner registers under the guest host name, which computer_names lists."
  value       = local.use_vm ? keys(local.all_vms) : [var.name_prefix]
}

output "computer_names" {
  description = "Host names inside the guest, which is the name each runner registers under (VM mode)."
  value       = [for k, v in local.all_vms : v.computer_name]
}

output "vm_ids" {
  description = "VM resource IDs (VM mode), or the scale set ID."
  value = local.use_vm ? concat(
    [for k, v in azurerm_linux_virtual_machine.this : v.id],
    [for k, v in azurerm_windows_virtual_machine.this : v.id],
  ) : [for s in azurerm_linux_virtual_machine_scale_set.this : s.id]
}

output "private_ip_addresses" {
  description = "Private IP addresses of the VMs."
  value       = [for k, v in azurerm_network_interface.vm : v.private_ip_address]
}

output "identity_id" {
  description = "Resource ID of the runner's user-assigned managed identity."
  value       = azurerm_user_assigned_identity.this.id
}

output "identity_principal_id" {
  description = "Object ID of the managed identity. Use it for role assignments the module does not make."
  value       = azurerm_user_assigned_identity.this.principal_id
}

output "identity_client_id" {
  description = "Client ID of the managed identity. Pass it to Connect-AzAccount -AccountId, or az login --identity --client-id."
  value       = azurerm_user_assigned_identity.this.client_id
}

output "role_assignments" {
  description = "Role assignments made for the identity, by key: role and scope."
  value       = { for k, v in local.role_assignments : k => { role = v.role, scope = v.scope } }
}

output "labels" {
  description = "Labels the runners register with (GitHub labels, Azure Pipelines capabilities, GitLab tags when the legacy flow is used)."
  value       = local.labels
}

output "platform" {
  description = "The platform the runners register with."
  value       = local.platform
}

output "subnet_id" {
  description = "Subnet the runners are in."
  value       = local.subnet_id
}

output "vnet_name" {
  description = "VNet of the runners' subnet when the module created it or was given existing_vnet. Null with existing_subnet_id."
  value       = local.vnet_name
}

output "vnet_resource_group_name" {
  description = "Resource group of that VNet."
  value       = local.vnet_resource_group
}

output "vnet_id" {
  description = "VNet the module created. Null otherwise."
  value       = one(azurerm_virtual_network.this[*].id)
}

output "nsg_id" {
  description = "Network security group of the runners."
  value       = azurerm_network_security_group.this.id
}
