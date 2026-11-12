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

variable "defender_plans" {
  description = "Paid Microsoft Defender for Cloud plans to turn on, by plan name. Empty by default: the toolkit turns on no paid plan. The free level Azure Local needs is set by Enable-DefenderForCloud.ps1."
  type = map(object({
    enabled = bool
  }))
  default = {}
}

variable "policy_assignments" {
  description = "Subscription-level Azure Policy assignments."
  type = map(object({
    policy_definition_id   = string
    display_name           = string
    description            = optional(string, "")
    enforce                = optional(bool, true)
    non_compliance_message = optional(string, "")
  }))
  default = {}
}

variable "rg_policy_assignments" {
  description = "Resource-group-level Azure Policy assignments."
  type = map(object({
    resource_group_id    = string
    policy_definition_id = string
    display_name         = string
    description          = optional(string, "")
    enforce              = optional(bool, true)
  }))
  default = {}
}
