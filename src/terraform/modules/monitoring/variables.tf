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

variable "org_code" {
  description = "Organization code for naming (e.g., iic)."
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
  description = "Email addresses for critical alert notifications."
  type        = list(string)
  default     = []
}

variable "enable_cluster_alerts" {
  description = "Whether to create Azure Local cluster health alerts."
  type        = bool
  default     = false
}

variable "alert_scopes" {
  description = "Resource IDs to scope alerts to."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags to apply to all monitoring resources."
  type        = map(string)
  default     = {}
}
