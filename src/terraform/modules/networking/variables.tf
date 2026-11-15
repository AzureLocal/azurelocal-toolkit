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
  description = "Resource group of the hub virtual network, its subnets and NSGs."
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
  description = "NSGs with rules (landing_zone.network_security_groups[]): one value in each address and port field of a rule."
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
      source_port_range          = string
      destination_address_prefix = string
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

variable "nat_config" {
  description = "NAT gateway (landing_zone.connectivity.nat_gateway): name, the name of its public IP, SKU (Standard or StandardV2), resource group, network (the hub) and the hub subnets it serves."
  type = object({
    name           = optional(string, "")
    public_ip_name = optional(string, "")
    sku            = optional(string)
    resource_group = optional(string, "")
    network        = optional(string, "")
    subnets        = optional(list(string), [])
  })
  default = {}

  validation {
    condition     = var.nat_config.sku == null || contains(["Standard", "StandardV2"], coalesce(var.nat_config.sku, "Standard"))
    error_message = "landing_zone.connectivity.nat_gateway.sku must be Standard or StandardV2."
  }
}

# --- VPN Gateway ---
variable "enable_vpn_gateway" {
  description = "Whether to deploy a VPN Gateway."
  type        = bool
  default     = false
}

variable "vpn_config" {
  description = "VPN Gateway configuration (landing_zone.connectivity.vpn_gateway and its first site_to_site entry)."
  type = object({
    gateway_name             = string
    resource_group           = optional(string, "")
    network                  = optional(string, "")
    public_ip_name           = optional(string, "")
    secondary_public_ip_name = optional(string, "")
    sku                      = optional(string)
    active_active            = optional(bool)
    bgp_enabled              = optional(bool, false)
    bgp_asn                  = optional(number)
    local_gateway_name       = string
    local_gateway_ip         = string
    local_address_prefixes   = list(string)
    peer_asn                 = optional(number)
    peer_bgp_address         = optional(string)
    connection_name          = string
    routing_weight           = optional(number, 0)
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

variable "vpn_ip_configuration_name" {
  description = "Name of the IP configuration of the VPN gateway (of the first instance in active-active mode)."
  type        = string
  default     = "vnetGatewayConfig"
}

variable "vpn_secondary_ip_configuration_name" {
  description = "Name of the IP configuration of the second instance of an active-active VPN gateway."
  type        = string
  default     = "vnetGatewayConfig2"
}

# --- Bastion ---
variable "enable_bastion" {
  description = "Whether to deploy Azure Bastion."
  type        = bool
  default     = false
}

variable "bastion_config" {
  description = "Bastion host configuration (landing_zone.connectivity.bastion)."
  type = object({
    name           = string
    resource_group = optional(string, "")
    network        = optional(string, "")
    public_ip_name = optional(string, "")
    sku            = optional(string)
  })
  default = {
    name = ""
  }
}

variable "bastion_ip_configuration_name" {
  description = "Name of the IP configuration of the Bastion host."
  type        = string
  default     = "bastionIpConfig"
}

variable "tags" {
  description = "Tags to apply to all networking resources."
  type        = map(string)
  default     = {}
}
