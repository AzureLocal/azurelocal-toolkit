# =============================================================================
# Backend Bootstrap Outputs
# =============================================================================

output "resource_group_name" {
  description = "Name of the resource group containing the state storage."
  value       = azurerm_resource_group.tfstate.name
}

output "storage_account_name" {
  description = "Name of the storage account for Terraform state."
  value       = azurerm_storage_account.tfstate.name
}

output "container_name" {
  description = "Name of the blob container for state files."
  value       = azurerm_storage_container.tfstate.name
}

output "backend_config" {
  description = "Backend settings for terraform init -backend-config. New-IacVariableFiles.ps1 writes the same values to backend.hcl from devops.state."
  value       = <<-EOT
    resource_group_name  = "${azurerm_resource_group.tfstate.name}"
    storage_account_name = "${azurerm_storage_account.tfstate.name}"
    container_name       = "${azurerm_storage_container.tfstate.name}"
    use_azuread_auth     = true
  EOT
}
