# =============================================================================
# Backend Bootstrap Variables
# =============================================================================

variable "subscription_id" {
  description = "Azure subscription ID for the Terraform state storage account."
  type        = string
}

variable "location" {
  description = "Azure region for the state storage resources."
  type        = string
  default     = "eastus"
}

variable "org_code" {
  description = "Organization code used in resource naming (e.g., IIC)."
  type        = string
  default     = "iic"

  validation {
    condition     = can(regex("^[a-zA-Z]{2,10}$", var.org_code))
    error_message = "org_code must be 2-10 alphabetic characters."
  }
}

variable "environment" {
  description = "Environment name (lab, dev, staging, prod)."
  type        = string
  default     = "lab"

  validation {
    condition     = contains(["lab", "dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: lab, dev, staging, prod."
  }
}

variable "owner" {
  description = "Owner email for resource tagging."
  type        = string
  default     = "admin@contoso.cloud"
}

variable "allowed_ip_ranges" {
  description = "List of public IP CIDR ranges allowed to access the state storage account."
  type        = list(string)
  default     = []
}
