# =============================================================================
# Azure Local Environment — Variables
# =============================================================================
# Every value that is a fact of the environment comes from infrastructure.yml:
#   pwsh config/variables/scripts/New-IacVariableFiles.ps1
#       -InfrastructureFile ./infrastructure.yml -OutputDirectory <folder outside the repository>
# writes terraform/azure-local/terraform.tfvars.json. The registry
# (config/variables/schema/master-registry.yaml, tools.terraform.variables) says,
# for every variable here, which key of infrastructure.yml it comes from, or that
# it is a setting of the Terraform code itself. A secret is never written to a
# file: pass it as TF_VAR_<name> in the environment.
# =============================================================================

# --- General ---
variable "org_code" {
  description = "Short lowercase organization code used in the names of the NAT gateway and its public IP (site.code, lowercase)."
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
  description = "Subscription IDs by role. An empty ID leaves that subscription out of the management group association."
  type = object({
    connectivity_id = optional(string, "")
    identity_id     = optional(string, "")
    management_id   = optional(string, "")
    security_id     = optional(string, "")
    azure_local_id  = string
    workloads_id    = optional(string, "")
  })
}

# --- Landing Zone ---
variable "management_groups" {
  description = "Management group hierarchy names."
  type = object({
    root_name             = string
    root_display_name     = string
    platform_name         = string
    platform_display_name = string
    identity_name         = string
    connectivity_name     = string
    management_name       = string
    security_name         = string
    landing_zones_name    = string
  })
}

variable "resource_groups" {
  description = "Map of resource group name to name, one entry for each resource group the landing zone lists."
  type        = map(string)
}

variable "hub_resource_group_name" {
  description = "Resource group of the hub virtual network. It must be one of resource_groups."
  type        = string
}

variable "monitoring_resource_group_name" {
  description = "Resource group of the Log Analytics workspace and the action group. It must be one of resource_groups."
  type        = string
}

variable "identity_resource_group_name" {
  description = "Resource group of the platform Key Vault. It must be one of resource_groups."
  type        = string
}

variable "azl_key_vault_resource_group_name" {
  description = "Resource group of the Azure Local cluster Key Vault. It must be one of resource_groups."
  type        = string
  default     = ""
}

variable "compute_resource_group_name" {
  description = "Resource group of the management VMs. It must be one of resource_groups."
  type        = string
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
  description = "Subnet configurations by key. The gateway and Bastion subnets use the keys gateway and bastion."
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
  description = "Whether to deploy a NAT Gateway."
  type        = bool
  default     = true
}

variable "nat_gateway_idle_timeout" {
  description = "NAT Gateway idle timeout in minutes."
  type        = number
  default     = 4
}

variable "enable_vpn_gateway" {
  description = "Whether to deploy a VPN Gateway (landing_zone.connectivity.vpn_gateway)."
  type        = bool
  default     = false
}

variable "vpn_config" {
  description = "VPN Gateway configuration."
  type = object({
    gateway_name           = string
    public_ip_name         = optional(string, "")
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
    local_gateway_name     = ""
    local_gateway_ip       = ""
    local_address_prefixes = []
    connection_name        = ""
  }
}

variable "vpn_shared_key" {
  description = "VPN connection shared key. A secret: pass it as TF_VAR_vpn_shared_key."
  type        = string
  sensitive   = true
  default     = ""
}

variable "enable_bastion" {
  description = "Whether to deploy Azure Bastion (landing_zone.connectivity.bastion)."
  type        = bool
  default     = false
}

variable "bastion_config" {
  description = "Bastion host configuration."
  type = object({
    name           = string
    public_ip_name = optional(string, "")
    sku            = optional(string, "Standard")
  })
  default = {
    name = ""
  }
}

# --- Identity ---
variable "key_vault_name" {
  description = "Platform Key Vault name."
  type        = string
}

variable "key_vault_allowed_ips" {
  description = "IP ranges allowed to reach the Key Vaults."
  type        = list(string)
  default     = []
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
  description = "Subscription-level roles of the deployment service principal."
  type        = list(string)
  default     = ["Contributor", "User Access Administrator", "Azure Stack HCI Administrator", "Reader"]
}

variable "spn_resource_group_roles" {
  description = "Resource-group-level roles of the deployment service principal."
  type = map(object({
    scope = string
    roles = list(string)
  }))
  default = {}
}

variable "managed_identities" {
  description = "User-assigned managed identities to create."
  type = map(object({
    name           = string
    resource_group = string
  }))
  default = {}
}

# --- Monitoring ---
variable "log_analytics_workspace_name" {
  description = "Log Analytics workspace name."
  type        = string
}

variable "log_analytics_sku" {
  description = "Log Analytics workspace SKU. PerGB2018 is the pay-as-you-go tier, the only one Azure offers for a new workspace; not a choice of the deployment."
  type        = string
  default     = "PerGB2018"
}

variable "log_analytics_retention_days" {
  description = "Days the workspace keeps data (operations.monitoring.retention_days). Null leaves the Azure default, which is the registry default of the key."
  type        = number
  default     = null
}

variable "action_group_name" {
  description = "Name of the Azure Monitor action group."
  type        = string
}

variable "alert_email_addresses" {
  description = "Addresses that receive the notifications of the action group."
  type        = list(string)
  default     = []
}

# --- Security ---
variable "security_contact_email" {
  description = "Address that Microsoft Defender for Cloud sends security notifications to."
  type        = string
  default     = ""
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

# --- Compute ---
variable "management_vms" {
  description = "Management VMs (landing_zone.virtual_machines). subnet_key is the key of a subnet in subnets."
  type = map(object({
    vm_name           = string
    hostname          = string
    private_ip        = string
    vm_size           = string
    subnet_key        = string
    os_disk_size_gb   = optional(number, 128)
    os_disk_type      = optional(string, "Premium_LRS")
    role              = string
    deployment_target = string
  }))
  default = {}
}

variable "vm_admin_username" {
  description = "Local administrator of the management VMs."
  type        = string
  default     = "azlocaladmin"
}

variable "vm_admin_password" {
  description = "Local administrator password of the management VMs. A secret: pass it as TF_VAR_vm_admin_password."
  type        = string
  sensitive   = true
}

variable "windows_server_sku" {
  description = "Windows Server image SKU of the management VMs."
  type        = string
  default     = "2025-datacenter-azure-edition"
}
