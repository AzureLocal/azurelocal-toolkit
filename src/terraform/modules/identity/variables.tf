# =============================================================================
# Identity Module — Variables
# =============================================================================

variable "key_vault_name" {
  description = "Name of the platform Key Vault."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for the Key Vault."
  type        = string
}

variable "key_vault_allowed_ips" {
  description = "IP ranges allowed to access Key Vault."
  type        = list(string)
  default     = []
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID for Key Vault diagnostics."
  type        = string
  default     = ""
}

variable "azl_key_vault_name" {
  description = "Name of the Azure Local cluster Key Vault (optional)."
  type        = string
  default     = ""
}

variable "azl_key_vault_resource_group" {
  description = "Resource group for the Azure Local Key Vault."
  type        = string
  default     = ""
}

variable "deployment_spn_object_id" {
  description = "Object ID of the deployment service principal (sp-azurelocal-deploy)."
  type        = string
}

variable "azure_local_subscription_id" {
  description = "Subscription ID for the Azure Local resources."
  type        = string
}

variable "spn_subscription_roles" {
  description = "Subscription-level RBAC roles for the deployment SPN."
  type        = list(string)
  default = [
    "Contributor",
    "User Access Administrator",
    "Azure Stack HCI Administrator",
    "Reader"
  ]
}

variable "spn_resource_group_roles" {
  description = "Resource-group-level RBAC roles for the deployment SPN."
  type = map(object({
    scope = string
    roles = list(string)
  }))
  default = {}
}

variable "managed_identities" {
  description = "Map of managed identity configurations to create."
  type = map(object({
    name           = string
    resource_group = string
  }))
  default = {}
}

variable "tags" {
  description = "Tags to apply to all identity resources."
  type        = map(string)
  default     = {}
}
