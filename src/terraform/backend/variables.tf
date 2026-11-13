# =============================================================================
# Backend Bootstrap Variables
# =============================================================================
# Every value comes from devops.state, azure, tags and environment of
# infrastructure.yml: config/variables/scripts/New-IacVariableFiles.ps1 writes
# terraform.tfvars.json for this folder.
# =============================================================================

variable "subscription_id" {
  description = "Azure subscription ID for the Terraform state storage account."
  type        = string
}

variable "location" {
  description = "Azure region for the state storage resources."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group that holds the state storage account."
  type        = string
}

variable "storage_account_name" {
  description = "Name of the state storage account (3 to 24 lowercase letters and digits)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "storage_account_name must be 3 to 24 lowercase letters and digits."
  }
}

variable "container_name" {
  description = "Blob container that holds the state files."
  type        = string
  default     = "tfstate"
}

variable "tags" {
  description = "Tags for the state resources."
  type        = map(string)
  default     = {}
}

variable "allowed_ip_ranges" {
  description = "List of public IP CIDR ranges allowed to access the state storage account."
  type        = list(string)
  default     = []
}
