# =============================================================================
# Security Module — Variables
# =============================================================================

variable "subscription_id" {
  description = "Subscription ID to apply policies to."
  type        = string
}

variable "security_contact_email" {
  description = "Email address for Defender for Cloud security contact."
  type        = string
  default     = ""
}

variable "alert_notifications" {
  description = "Send the security contact the security alerts (security.defender_for_cloud.alert_notifications)."
  type        = bool
}

variable "alerts_to_admins" {
  description = "Send the security alerts to the subscription owners too (security.defender_for_cloud.alerts_to_admins)."
  type        = bool
}

variable "policy_assignments" {
  description = "Subscription-level Azure Policy assignments by name (landing_zone.policy.assignments[])."
  type = map(object({
    policy_definition_id   = string
    display_name           = string
    description            = optional(string, "")
    enforce                = bool
    non_compliance_message = optional(string, "")
  }))
  default = {}
}

variable "rg_policy_assignments" {
  description = "Resource-group-level Azure Policy assignments by name (landing_zone.policy.resource_group_assignments[]); resource_group_id is the ID of the resource group the entry names."
  type = map(object({
    resource_group_id      = string
    policy_definition_id   = string
    display_name           = string
    description            = optional(string, "")
    enforce                = bool
    non_compliance_message = optional(string, "")
  }))
  default = {}
}
