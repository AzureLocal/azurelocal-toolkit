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
  description = "Backend configuration block to copy into environment modules."
  value = <<-EOT
    # Copy this into your environment's backend.tf:
    terraform {
      backend "azurerm" {
        resource_group_name  = "${azurerm_resource_group.tfstate.name}"
        storage_account_name = "${azurerm_storage_account.tfstate.name}"
        container_name       = "${azurerm_storage_container.tfstate.name}"
        key                  = "azure-local.tfstate"
      }
    }
  EOT
}
