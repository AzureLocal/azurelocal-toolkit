# =============================================================================
# Networking Module — Variables
# =============================================================================

variable "vnet_name" {
  description = "Name of the hub virtual network."
  type        = string
}

variable "vnet_address_space" {
  description = "Address space for the hub VNet."
  type        = list(string)
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for networking resources."
  type        = string
}

variable "org_code" {
  description = "Organization code for naming (e.g., iic)."
  type        = string
}

variable "dns_servers" {
  description = "Custom DNS servers for the VNet."
  type        = list(string)
  default     = []
}

variable "subnets" {
  description = "Map of subnet key to subnet configuration."
  type = map(object({
    name           = string
    address_prefix = string
  }))
}

variable "nsgs" {
  description = "List of NSGs with rules."
  type = list(object({
    name        = string
    description = optional(string, "")
    rules = list(object({
      name                       = string
      priority                   = number
      direction                  = string
      access                     = string
      protocol                   = string
      source_address_prefix      = string
      destination_port_range     = string
      source_port_range          = optional(string, "*")
      destination_address_prefix = optional(string, "*")
    }))
  }))
  default = []
}

variable "nsg_subnet_map" {
  description = "Map of subnet key to NSG name for association."
  type        = map(string)
  default     = {}
}

# --- NAT Gateway ---
variable "enable_nat_gateway" {
  description = "Whether to deploy a NAT Gateway (landing_zone.connectivity.nat_gateway)."
  type        = bool
  default     = false
}

variable "nat_gateway_idle_timeout" {
  description = "NAT Gateway idle timeout in minutes, 4 to 120 (landing_zone.connectivity.nat_gateway.idle_timeout_minutes). Not set: the Azure default of 4 minutes."
  type        = number
  default     = null

  validation {
    condition     = var.nat_gateway_idle_timeout == null || (var.nat_gateway_idle_timeout >= 4 && var.nat_gateway_idle_timeout <= 120)
    error_message = "The idle timeout is 4 to 120 minutes."
  }
}

# --- VPN Gateway ---
variable "enable_vpn_gateway" {
  description = "Whether to deploy a VPN Gateway."
  type        = bool
  default     = false
}

variable "vpn_config" {
  description = "VPN Gateway configuration."
  type = object({
    gateway_name           = string
    public_ip_name         = optional(string, "")
    sku                    = optional(string)
    active_active          = optional(bool, false)
    bgp_enabled            = optional(bool, false)
    local_gateway_name     = string
    local_gateway_ip       = string
    local_address_prefixes = list(string)
    connection_name        = string
    routing_weight         = optional(number, 0)
  })
  default = {
    gateway_name           = ""
    local_gateway_name     = ""
    local_gateway_ip       = ""
    local_address_prefixes = []
    connection_name        = ""
  }
}

variable "vpn_shared_key" {
  description = "Shared key for the VPN connection. Resolve from Key Vault at runtime."
  type        = string
  sensitive   = true
  default     = ""
}

# --- Bastion ---
variable "enable_bastion" {
  description = "Whether to deploy Azure Bastion."
  type        = bool
  default     = false
}

variable "bastion_config" {
  description = "Bastion host configuration."
  type = object({
    name           = string
    public_ip_name = optional(string, "")
    sku            = optional(string)
  })
  default = {
    name = ""
  }
}

variable "tags" {
  description = "Tags to apply to all networking resources."
  type        = map(string)
  default     = {}
}
