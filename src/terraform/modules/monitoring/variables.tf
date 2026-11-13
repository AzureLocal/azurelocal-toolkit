# =============================================================================
# Monitoring Module — Variables
# =============================================================================

variable "workspace_name" {
  description = "Name of the Log Analytics workspace."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for monitoring resources."
  type        = string
}

variable "action_group_name" {
  description = "Name of the Azure Monitor action group (operations.monitoring.action_group)."
  type        = string
}

variable "sku" {
  description = "Log Analytics workspace SKU."
  type        = string
  default     = "PerGB2018"
}

variable "retention_days" {
  description = "Log retention period in days."
  type        = number
  default     = 90
}

variable "alert_email_addresses" {
  description = "Email addresses that receive the notifications of the action group."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags to apply to all monitoring resources."
  type        = map(string)
  default     = {}
}
