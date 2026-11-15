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
  description = "Log Analytics workspace SKU. PerGB2018 is the pay-as-you-go pricing tier Microsoft names for a new workspace (Microsoft Learn: Azure Monitor Logs pricing details); not a choice of a deployment."
  type        = string
  default     = "PerGB2018"
}

variable "retention_days" {
  description = "Log retention period in days (operations.monitoring.retention_days). Null leaves the Azure default, which is the registry default of the key."
  type        = number
  default     = null
}

variable "alert_email_addresses" {
  description = "Email addresses that receive the notifications of the action group."
  type        = list(string)
  default     = []
}

variable "email_receiver_name_prefix" {
  description = "Prefix of the name of each email receiver of the action group; the position of the address in alert_email_addresses follows it."
  type        = string
  default     = "email-"
}

variable "tags" {
  description = "Tags to apply to all monitoring resources."
  type        = map(string)
  default     = {}
}
