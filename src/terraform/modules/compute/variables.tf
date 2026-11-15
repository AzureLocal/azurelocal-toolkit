# =============================================================================
# Compute Module — Variables
# =============================================================================

variable "management_vms" {
  description = "Map of management VMs to deploy (landing_zone.virtual_machines of infrastructure.yml), each with its own keys."
  type = map(object({
    vm_name                    = string
    hostname                   = string
    private_ip                 = string
    vm_size                    = string
    subnet_id                  = string
    resource_group             = string
    admin_username             = string
    admin_password_secret_name = optional(string, "")
    windows_server_sku         = string
    image_version              = string
    os_disk_size_gb            = number
    os_disk_type               = string
    os_disk_caching            = string
    role                       = string
    deployment_target          = string # "azure" | "azurelocal" | "onprem"
  }))
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "admin_password" {
  description = "Local admin password for VMs. Resolve from Key Vault at runtime."
  type        = string
  sensitive   = true
}

variable "key_vault_id" {
  description = "Key Vault that holds the administrator password under the secret each VM names (landing_zone.virtual_machines[].admin_password)."
  type        = string
  default     = ""
}

variable "nic_name_prefix" {
  description = "Prefix of the name of each VM network interface; the VM name follows it."
  type        = string
  default     = "nic-"
}

variable "ip_configuration_name" {
  description = "Name of the IP configuration of each VM network interface."
  type        = string
  default     = "internal"
}

variable "os_disk_name_prefix" {
  description = "Prefix of the name of each VM OS disk; the VM name follows it."
  type        = string
  default     = "osdisk-"
}

variable "identity_type" {
  description = "Managed identity of each VM: a system-assigned identity, which the Arc and monitoring agents use."
  type        = string
  default     = "SystemAssigned"
}

variable "boot_diagnostics_enabled" {
  description = "Boot diagnostics with a managed storage account on each VM."
  type        = bool
  default     = true
}

variable "role_tag_name" {
  description = "Name of the tag that carries landing_zone.virtual_machines[].role."
  type        = string
  default     = "Role"
}

variable "secret_content_type" {
  description = "Content type of the administrator password secret in Key Vault."
  type        = string
  default     = "password"
}

variable "tags" {
  description = "Tags to apply to all compute resources."
  type        = map(string)
  default     = {}
}
