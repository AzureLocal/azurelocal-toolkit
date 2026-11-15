# =============================================================================
# Azure Local Environment — Variables
# =============================================================================
# Every value that is a fact of the environment comes from infrastructure.yml:
#   pwsh config/variables/scripts/New-IacVariableFiles.ps1
#       -InfrastructureFile ./infrastructure.yml -OutputDirectory <folder outside the repository>
# writes terraform/azure-local/terraform.tfvars.json. The registry
# (config/variables/schema/master-registry.yaml, tools.terraform.variables) says,
# for every variable here, which key of infrastructure.yml it comes from (a key the
# file leaves out gets its registry default), or that it is a setting of the
# Terraform code itself (a variable with a default). A secret is never written to a
# file: pass it as TF_VAR_<name> in the environment.
# =============================================================================

# --- General ---
variable "location" {
  description = "Azure region for all resources."
  type        = string
}

variable "tags" {
  description = "Default tags for all resources."
  type        = map(string)
}

variable "azure_local_subscription_id" {
  description = "Subscription of the Azure Local resources (azure.subscription_id): the provider, the policy assignments and the roles of the deployment principal."
  type        = string
}

variable "purge_soft_delete_on_destroy" {
  description = "Provider setting: purge a Key Vault when terraform destroy deletes it. False keeps the soft-deleted vault recoverable."
  type        = bool
  default     = false
}

variable "prevent_deletion_if_contains_resources" {
  description = "Provider setting: refuse to delete a resource group that still holds resources Terraform does not manage."
  type        = bool
  default     = true
}

# --- Landing Zone ---
variable "management_groups" {
  description = "The management groups (landing_zone.management_groups[]): name, display name and the name of the parent group (empty: the tenant root group)."
  type = list(object({
    name         = string
    display_name = optional(string)
    parent       = optional(string)
  }))
}

variable "subscriptions" {
  description = "The subscriptions (landing_zone.subscriptions[]): name, id and the management group each one goes under. One with no id or no management group is left where it is."
  type = list(object({
    name             = string
    id               = optional(string, "")
    management_group = optional(string, "")
  }))
  default = []
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
  description = "NSG configurations with rules (landing_zone.network_security_groups[])."
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
  description = "Map of subnet key to NSG name."
  type        = map(string)
  default     = {}
}

variable "enable_nat_gateway" {
  description = "Whether to deploy a NAT Gateway (landing_zone.connectivity.nat_gateway)."
  type        = bool
  default     = false
}

variable "nat_gateway_idle_timeout" {
  description = "NAT Gateway idle timeout in minutes, 4 to 120 (landing_zone.connectivity.nat_gateway.idle_timeout_minutes). Not set: the Azure default of 4 minutes."
  type        = number
  default     = null
}

variable "nat_config" {
  description = "NAT gateway (landing_zone.connectivity.nat_gateway): name, the name of its public IP, SKU, resource group, network and the hub subnets it serves."
  type = object({
    name           = optional(string, "")
    public_ip_name = optional(string, "")
    sku            = optional(string)
    resource_group = optional(string, "")
    network        = optional(string, "")
    subnets        = optional(list(string), [])
  })
  default = {}
}

variable "enable_vpn_gateway" {
  description = "Whether to deploy a VPN Gateway (landing_zone.connectivity.vpn_gateway)."
  type        = bool
  default     = false
}

variable "vpn_config" {
  description = "VPN Gateway configuration."
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
    resource_group = optional(string, "")
    network        = optional(string, "")
    public_ip_name = optional(string, "")
    sku            = optional(string)
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
  description = "IP ranges allowed to reach the platform Key Vault (key_vaults[purpose=management].allowed_ip_ranges)."
  type        = list(string)
  default     = []
}

variable "key_vault_soft_delete_retention_days" {
  description = "Days a deleted secret or the platform Key Vault stays recoverable, 7 to 90 (key_vaults[purpose=management].soft_delete_retention_days)."
  type        = number
}

variable "azl_key_vault_name" {
  description = "Azure Local cluster Key Vault name."
  type        = string
  default     = ""
}

variable "azl_key_vault_soft_delete_retention_days" {
  description = "Days a deleted secret or the cluster Key Vault stays recoverable, 7 to 90 (cluster.key_vault.soft_delete_retention_days)."
  type        = number
}

variable "environment_class" {
  description = "The class of the environment (scenario.environment_class). Purge protection of the platform Key Vault is off in lab, test and dev; the cluster Key Vault has none, as Microsoft's deployment template creates it."
  type        = string
}

variable "deployment_spn_object_id" {
  description = "Object ID of the deployment service principal."
  type        = string
}

variable "spn_subscription_roles" {
  description = "Subscription-level roles of the deployment service principal."
  type        = list(string)
  default     = []
}

variable "spn_resource_group_roles" {
  description = "Resource-group-level roles of the deployment service principal (azure.automation_identity.resource_group_roles[])."
  type = list(object({
    resource_group = string
    roles          = list(string)
  }))
  default = []
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
  description = "Log Analytics workspace SKU. PerGB2018 is the pay-as-you-go pricing tier Microsoft names for a new workspace (Microsoft Learn: Azure Monitor Logs pricing details); not a choice of a deployment."
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
  description = "Resource-group-level Azure Policy assignments by name (landing_zone.policy.resource_group_assignments[]). resource_group must be one of resource_groups."
  type = map(object({
    resource_group         = string
    policy_definition_id   = string
    display_name           = string
    description            = optional(string, "")
    enforce                = bool
    non_compliance_message = optional(string, "")
  }))
  default = {}
}

# --- Compute ---
variable "management_vms" {
  description = "Management VMs (landing_zone.virtual_machines[] with deploy_target azure), each with its own keys. subnet_key is the key of a subnet in subnets; resource_group must be one of resource_groups."
  type = map(object({
    vm_name                    = string
    hostname                   = string
    private_ip                 = string
    vm_size                    = string
    subnet_key                 = string
    resource_group             = string
    admin_username             = string
    admin_password_secret_name = optional(string, "")
    windows_server_sku         = string
    image_version              = string
    os_disk_size_gb            = number
    os_disk_type               = string
    os_disk_caching            = string
    role                       = string
    deployment_target          = string
  }))
  default = {}
}

variable "vm_admin_password" {
  description = "Local administrator password of the management VMs. A secret: pass it as TF_VAR_vm_admin_password."
  type        = string
  sensitive   = true
}
