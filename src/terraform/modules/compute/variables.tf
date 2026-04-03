# =============================================================================
# Compute Module — Variables
# =============================================================================

variable "management_vms" {
  description = "Map of management VMs to deploy. Sourced from compute.vms.management in variables.yml."
  type = map(object({
    vm_name           = string
    hostname          = string
    private_ip        = string
    vm_size           = string
    subnet_id         = string
    os_disk_size_gb   = number
    os_disk_type      = string
    role              = string
    deployment_target = string # "azure" | "azurelocal" | "onprem"
  }))
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for compute resources."
  type        = string
}

variable "admin_username" {
  description = "Local admin username for VMs."
  type        = string
  default     = "azlocaladmin"
}

variable "admin_password" {
  description = "Local admin password for VMs. Resolve from Key Vault at runtime."
  type        = string
  sensitive   = true
}

variable "windows_server_sku" {
  description = "Windows Server image SKU."
  type        = string
  default     = "2025-datacenter-azure-edition"
}

variable "key_vault_id" {
  description = "Key Vault ID for storing VM credentials."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags to apply to all compute resources."
  type        = map(string)
  default     = {}
}
