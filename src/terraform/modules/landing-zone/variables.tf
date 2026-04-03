# =============================================================================
# Landing Zone Module — Variables
# =============================================================================

variable "management_groups" {
  description = "Management group hierarchy configuration."
  type = object({
    parent_id              = optional(string, null)
    root_name              = string
    root_display_name      = string
    platform_name          = string
    platform_display_name  = string
    identity_name          = string
    connectivity_name      = string
    management_name        = string
    security_name          = string
    landing_zones_name     = string
  })
}

variable "subscriptions" {
  description = "Subscription IDs for management group association."
  type = object({
    connectivity_id = optional(string, "")
    identity_id     = optional(string, "")
    management_id   = optional(string, "")
    security_id     = optional(string, "")
    azure_local_id  = optional(string, "")
    workloads_id    = optional(string, "")
  })
  default = {}
}

variable "resource_groups" {
  description = "Map of resource group key to name. All created in var.location."
  type        = map(string)
  default     = {}
}

variable "location" {
  description = "Azure region for all resource groups."
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resource groups."
  type        = map(string)
  default     = {}
}
