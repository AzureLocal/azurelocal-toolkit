# =============================================================================
# Azure Local Environment — Variables
# =============================================================================
# All variables are sourced from config/variables/variables.yml via
# Export-TerraformTfvars or manually maintained terraform.tfvars.
# =============================================================================

# --- General ---
variable "org_code" {
  description = "Organization code (e.g., iic)."
  type        = string
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
}

variable "tags" {
  description = "Default tags for all resources."
  type        = map(string)
}

# --- Subscriptions ---
variable "subscriptions" {
  description = "Subscription IDs by function."
  type = object({
    bootstrap_id    = optional(string, "")
    connectivity_id = string
    identity_id     = string
    management_id   = string
    security_id     = string
    azure_local_id  = string
    workloads_id    = optional(string, "")
  })
}

# --- Landing Zone ---
variable "management_groups" {
  description = "Management group hierarchy names."
  type = object({
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

variable "resource_groups" {
  description = "Map of resource group key to name."
  type        = map(string)
}

# --- Networking ---
variable "vnet_name" {
  description = "Hub VNet name."
  type        = string
}

variable "vnet_address_space" {
  description = "Hub VNet address space."
  type        = list(string)
}

variable "dns_servers" {
  description = "Custom DNS servers."
  type        = list(string)
  default     = []
}

variable "subnets" {
  description = "Subnet configurations."
  type = map(object({
    name           = string
    address_prefix = string
  }))
}

variable "nsgs" {
  description = "NSG configurations with rules."
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
  description = "Map of subnet key to NSG name."
  type        = map(string)
  default     = {}
}

variable "enable_nat_gateway" {
  type    = bool
  default = true
}

variable "nat_gateway_idle_timeout" {
  type    = number
  default = 4
}

variable "enable_vpn_gateway" {
  type    = bool
  default = false
}

variable "vpn_config" {
  description = "VPN Gateway configuration."
  type = object({
    gateway_name           = string
    public_ip_name         = string
    sku                    = optional(string, "VpnGw2AZ")
    generation             = optional(string, "Generation2")
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
    public_ip_name         = ""
    local_gateway_name     = ""
    local_gateway_ip       = ""
    local_address_prefixes = []
    connection_name        = ""
  }
}

variable "vpn_shared_key" {
  description = "VPN connection shared key."
  type        = string
  sensitive   = true
  default     = ""
}

variable "enable_bastion" {
  type    = bool
  default = true
}

variable "bastion_config" {
  type = object({
    name           = string
    public_ip_name = string
    sku            = optional(string, "Standard")
  })
  default = {
    name           = ""
    public_ip_name = ""
  }
}

# --- Identity ---
variable "key_vault_name" {
  description = "Platform Key Vault name."
  type        = string
}

variable "key_vault_allowed_ips" {
  type    = list(string)
  default = []
}

variable "azl_key_vault_name" {
  description = "Azure Local cluster Key Vault name."
  type        = string
  default     = ""
}

variable "deployment_spn_object_id" {
  description = "Object ID of the deployment service principal."
  type        = string
}

variable "spn_subscription_roles" {
  type    = list(string)
  default = ["Contributor", "User Access Administrator", "Azure Stack HCI Administrator", "Reader"]
}

variable "spn_resource_group_roles" {
  type = map(object({
    scope = string
    roles = list(string)
  }))
  default = {}
}

variable "managed_identities" {
  type = map(object({
    name           = string
    resource_group = string
  }))
  default = {}
}

# --- Monitoring ---
variable "log_analytics_workspace_name" {
  type = string
}

variable "log_analytics_sku" {
  type    = string
  default = "PerGB2018"
}

variable "log_analytics_retention_days" {
  type    = number
  default = 90
}

variable "alert_email_addresses" {
  type    = list(string)
  default = []
}

# --- Security ---
variable "security_contact_email" {
  type    = string
  default = ""
}

variable "defender_plans" {
  type = map(object({
    enabled = bool
  }))
  default = {
    VirtualMachines = { enabled = true }
    StorageAccounts = { enabled = true }
    KeyVaults       = { enabled = true }
    Dns             = { enabled = true }
    Arm             = { enabled = true }
  }
}

variable "policy_assignments" {
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
  type = map(object({
    resource_group_id    = string
    policy_definition_id = string
    display_name         = string
    description          = optional(string, "")
    enforce              = optional(bool, true)
  }))
  default = {}
}

# --- Compute ---
variable "management_vms" {
  description = "Management VM configurations from compute.vms.management."
  type = map(object({
    vm_name           = string
    hostname          = string
    private_ip        = string
    vm_size           = string
    subnet_id         = string
    os_disk_size_gb   = number
    os_disk_type      = string
    role              = string
    deployment_target = string
  }))
  default = {}
}

variable "vm_admin_username" {
  type    = string
  default = "azlocaladmin"
}

variable "vm_admin_password" {
  type      = string
  sensitive = true
}

variable "windows_server_sku" {
  type    = string
  default = "2025-datacenter-azure-edition"
}
