# =============================================================================
# Landing Zone Module — Variables
# =============================================================================

variable "management_groups" {
  description = "The management groups to create (landing_zone.management_groups[]): name, display name (empty uses the name) and the name of the parent group (empty: the tenant root group)."
  type = list(object({
    name         = string
    display_name = optional(string)
    parent       = optional(string)
  }))
  default = []
}

variable "subscriptions" {
  description = "The subscriptions to place (landing_zone.subscriptions[]): name, id and the name of the management group the subscription goes under. One with no id or no management group is left where it is."
  type = list(object({
    name             = string
    id               = optional(string, "")
    management_group = optional(string, "")
  }))
  default = []
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
