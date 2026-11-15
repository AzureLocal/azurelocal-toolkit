# =============================================================================
# Backend Bootstrap Variables
# =============================================================================
# Every value comes from devops.state, azure and tags of infrastructure.yml:
# config/variables/scripts/New-IacVariableFiles.ps1 writes terraform.tfvars.json
# for this folder (a key the file leaves out gets its registry default). A
# variable with a default is a setting of this code (class c in the registry).
# =============================================================================

variable "subscription_id" {
  description = "Azure subscription ID for the Terraform state storage account (devops.state.subscription_id, else azure.subscription_id)."
  type        = string
}

variable "location" {
  description = "Azure region for the state storage resources (azure.location)."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group that holds the state storage account (devops.state.resource_group)."
  type        = string
}

variable "storage_account_name" {
  description = "Name of the state storage account, 3 to 24 lowercase letters and digits (devops.state.storage_account)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "storage_account_name must be 3 to 24 lowercase letters and digits."
  }
}

variable "container_name" {
  description = "Blob container that holds the state files (devops.state.container)."
  type        = string
}

variable "tags" {
  description = "Tags for the state resources (tags)."
  type        = map(string)
  default     = {}
}

variable "state_tags" {
  description = "Tags this code adds to the state resources, on top of tags."
  type        = map(string)
  default = {
    ManagedBy = "Terraform"
    Purpose   = "Terraform Remote State"
  }
}

variable "account_tier" {
  description = "Performance tier of the state storage account. Standard: a general-purpose v2 account; Premium needs another account kind and LRS or ZRS (Microsoft Learn: Storage account overview)."
  type        = string
  default     = "Standard"
}

variable "replication_type" {
  description = "Redundancy of the state storage account: LRS, ZRS, GRS, RAGRS, GZRS or RAGZRS (devops.state.replication_type)."
  type        = string

  validation {
    condition     = contains(["LRS", "ZRS", "GRS", "RAGRS", "GZRS", "RAGZRS"], var.replication_type)
    error_message = "replication_type must be LRS, ZRS, GRS, RAGRS, GZRS or RAGZRS (devops.state.replication_type)."
  }
}

variable "public_network_access_enabled" {
  description = "Public network access of the state storage account (devops.state.public_network_access). False: private endpoints only, and allowed_ip_ranges must be empty."
  type        = bool
  default     = false
}

variable "versioning_enabled" {
  description = "Blob versioning of the state storage account (devops.state.versioning)."
  type        = bool
}

variable "blob_soft_delete_retention_days" {
  description = "Days a deleted state blob stays recoverable, 1 to 365 (devops.state.blob_soft_delete_days)."
  type        = number

  validation {
    condition     = var.blob_soft_delete_retention_days >= 1 && var.blob_soft_delete_retention_days <= 365
    error_message = "blob_soft_delete_retention_days must be 1 to 365 (devops.state.blob_soft_delete_days)."
  }
}

variable "container_soft_delete_retention_days" {
  description = "Days a deleted state container stays recoverable, 1 to 365 (devops.state.container_soft_delete_days)."
  type        = number

  validation {
    condition     = var.container_soft_delete_retention_days >= 1 && var.container_soft_delete_retention_days <= 365
    error_message = "container_soft_delete_retention_days must be 1 to 365 (devops.state.container_soft_delete_days)."
  }
}

variable "network_bypass" {
  description = "Traffic that passes the network rules of the state storage account: AzureServices, Logging, Metrics or None (devops.state.network_bypass)."
  type        = list(string)
}

variable "allowed_ip_ranges" {
  description = "Public IP addresses or CIDR ranges allowed to reach the state storage account (devops.state.allowed_ip_ranges). Needs public_network_access_enabled."
  type        = list(string)
  default     = []
}
