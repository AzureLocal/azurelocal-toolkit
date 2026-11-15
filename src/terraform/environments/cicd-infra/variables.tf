# =============================================================================
# CI/CD infrastructure - variables
# =============================================================================
# No secret is a variable. Every fact of the environment comes from infrastructure.yml:
# New-IacVariableFiles.ps1 (or task 06, Deploy-CicdRunners.ps1) writes the generated
# terraform.tfvars.json outside the repository, from the devops, azure, key_vaults,
# landing_zone and tags sections. A variable with a default is a setting of this code
# (class c under tools.cicd_infra.terraform_variables in the master registry).
# =============================================================================

# ------------------------------------------------------------------ azure ----

variable "tenant_id" {
  description = "Entra tenant ID. Null takes the signed-in tenant."
  type        = string
  default     = null
}

variable "subscription_id" {
  description = "Subscription that holds the runners (the DevOps subscription)."
  type        = string
}

variable "hub_subscription_id" {
  description = "Subscription that holds the hub VNet (the connectivity subscription). Null uses subscription_id."
  type        = string
  default     = null
}

variable "location" {
  description = "Azure region of the runners."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for the runners."
  type        = string
}

variable "create_resource_group" {
  description = "Create the resource group. False when it exists."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags for every resource."
  type        = map(string)
  default     = {}
}

variable "prevent_deletion_if_contains_resources" {
  description = "Provider setting: refuse to delete a resource group that still holds resources Terraform does not manage."
  type        = bool
  default     = true
}

variable "storage_use_azuread" {
  description = "Provider setting: reach storage with Entra ID, never with an account key."
  type        = bool
  default     = true
}

# --------------------------------------------------------------- platform ----

variable "platform" {
  description = "github, gitlab or azure_devops."
  type        = string
}

variable "scm_url" {
  description = "github: https://github.com/<org>[/<repo>]. gitlab: https://gitlab.com. azure_devops: https://dev.azure.com/<org>."
  type        = string
}

variable "github_runner_group" {
  description = "GitHub runner group of the general (Linux) runners (devops.runners[].pool). Empty uses the default group."
  type        = string
  default     = ""
}

variable "github_ztp_runner_group" {
  description = "GitHub runner group of the ZTP (Windows) runner (devops.runners[].pool of the ztp runner). Empty uses the default group."
  type        = string
  default     = ""
}

variable "azure_devops_pool" {
  description = "Azure Pipelines pool of the general (Linux) agents (devops.runners[].pool). Needed when platform is azure_devops; there is no default pool."
  type        = string
  default     = ""
}

variable "azure_devops_ztp_pool" {
  description = "Azure Pipelines pool of the ZTP (Windows) agent (devops.runners[].pool of the ztp runner). Its own pool: the agent has administrator rights and reaches the BMC network. Needed when platform is azure_devops; there is no default pool."
  type        = string
  default     = ""
}

variable "registration_secret" {
  description = "The Key Vault secret each runner reads at boot. See the module's registration_secret. ztp_secret_name overrides the secret name for the ZTP runner."
  type = object({
    key_vault_id    = string
    key_vault_name  = string
    secret_name     = string
    kind            = optional(string, "pat")
    ztp_secret_name = optional(string, "")
    dns_suffix      = optional(string, "vault.azure.net")
  })
}

# ---------------------------------------------------------------- runners ----

variable "admin_ssh_public_key" {
  description = "SSH public key for the Linux runners (public, not a secret)."
  type        = string
  default     = ""
}

variable "linux_runner" {
  description = "The general runner (devops.runners[] with os_type linux): Linux, for ARM, Arc, Terraform, Ansible and OS-configuration jobs."
  type = object({
    enabled              = bool
    os_type              = optional(string)
    purpose              = optional(string)
    name_prefix          = optional(string)
    computer_name_prefix = optional(string, "azlrunlnx")
    count                = optional(number)
    compute_type         = optional(string)
    vm_size              = optional(string)
    private_ip_addresses = optional(list(string), [])
    extra_labels         = optional(list(string), [])
    install_ansible      = optional(bool, true)
    nsg_name             = optional(string)
    identity_name        = optional(string)
    admin_username       = optional(string)
    os_disk_size_gb      = optional(number)
    os_disk_type         = optional(string)
    os_disk_caching      = optional(string)
    data_disk_caching    = optional(string)
    encryption_at_host   = optional(bool)
    zones                = optional(list(string), [])
    image = optional(object({
      publisher = string
      offer     = string
      sku       = string
      version   = string
    }))
  })
}

variable "ztp_runner" {
  description = "The ZTP runner (devops.runners[] with purpose ztp): one Windows VM that the BMCs can reach on TCP 445, for the azurelocal-ztp Boot, Bootstrap and Vouchers stages."
  type = object({
    enabled              = bool
    os_type              = optional(string)
    purpose              = optional(string)
    name_prefix          = optional(string)
    computer_name_prefix = optional(string, "azlrunztp")
    count                = optional(number)
    compute_type         = optional(string)
    vm_size              = optional(string)
    data_disk_size_gb    = optional(number)
    private_ip_addresses = optional(list(string), [])
    extra_labels         = optional(list(string), [])
    nsg_name             = optional(string)
    identity_name        = optional(string)
    admin_username       = optional(string)
    os_disk_size_gb      = optional(number)
    os_disk_type         = optional(string)
    os_disk_caching      = optional(string)
    data_disk_caching    = optional(string)
    encryption_at_host   = optional(bool)
    zones                = optional(list(string), [])
    image = optional(object({
      publisher = string
      offer     = string
      sku       = string
      version   = string
    }))
  })
}

# ---------------------------------------------------------------- network ----

variable "vnet_name" {
  description = "VNet to create."
  type        = string
}

variable "vnet_address_space" {
  description = "Address space of the VNet."
  type        = list(string)
}

variable "linux_subnet" {
  description = "Subnet of the Linux runners."
  type = object({
    name           = string
    address_prefix = string
  })
  default = null
}

variable "ztp_subnet" {
  description = "Subnet of the ZTP runner."
  type = object({
    name           = string
    address_prefix = string
  })
  default = null
}

variable "dns_servers" {
  description = "DNS servers of the VNet. Empty uses Azure DNS."
  type        = list(string)
  default     = []
}

variable "hub_peering" {
  description = "Peering with the hub VNet (see the module's hub_peering)."
  type = object({
    enabled                 = optional(bool, false)
    hub_vnet_id             = optional(string, "")
    use_remote_gateways     = optional(bool)
    create_hub_side         = optional(bool)
    spoke_name              = optional(string, "")
    hub_name                = optional(string, "")
    allow_forwarded_traffic = optional(bool)
    allow_gateway_transit   = optional(bool)
  })
  default = {}
}

variable "reachable_cidrs" {
  description = "The lab networks the runners reach: management, BMC, storage."
  type        = list(string)
  default     = []
}

variable "reachable_tcp_ports" {
  description = "TCP ports allowed outbound to the lab networks (devops.runner_network.reachable_tcp_ports)."
  type        = list(string)
}

variable "allow_internet_https" {
  description = "Allow HTTPS outbound to the internet (devops.runner_network.allow_internet_https)."
  type        = bool
}

variable "allow_internet_http" {
  description = "Allow HTTP outbound to the internet (devops.runner_network.allow_internet_http)."
  type        = bool
}

variable "allow_icmp" {
  description = "Allow ICMP outbound to the lab networks (devops.runner_network.allow_icmp)."
  type        = bool
}

variable "bmc_cidrs" {
  description = "The BMC networks. The ZTP runner accepts inbound TCP 445 from these only."
  type        = list(string)
  default     = []
}

variable "admin_source_cidrs" {
  description = "Ranges allowed to reach SSH or RDP on the runners. Empty allows none."
  type        = list(string)
  default     = []
}

# ----------------------------------------------------------------- access ----

variable "contributor_scopes" {
  description = "Scopes where the runners are Contributor: the Azure Local resource group and its managed-resources group."
  type        = list(string)
  default     = []
}

variable "rbac_administrator_scopes" {
  description = "Scopes where the runners are Role Based Access Control Administrator. Resource groups only."
  type        = list(string)
  default     = []
}

variable "rbac_administrator_delegable_role_ids" {
  description = "Role GUIDs the runners may assign. Empty allows any role."
  type        = list(string)
  default     = []
}

variable "arc_machine_scopes" {
  description = "Scopes where the runners can run Arc Run Command on machines."
  type        = list(string)
  default     = []
}

variable "key_vault_reader_ids" {
  description = "Other vaults (BMC, provisioning administrator, deployment administrator) the runners read secrets from."
  type        = list(string)
  default     = []
}

variable "additional_role_assignments" {
  description = "Any other role assignment of the runners (devops.runner_access.additional_role_assignments[]): { scope, role_definition_name }, keyed by its name."
  type = map(object({
    scope                = string
    role_definition_name = string
  }))
  default = {}
}

variable "windows_admin_password_secret_name" {
  description = "Write the generated Windows administrator password to this secret in the registration vault (devops.runners[].windows_admin_password_secret of the ztp runner). Empty keeps it in state only."
  type        = string
  default     = ""
}

variable "tool_versions" {
  description = "Tool versions for the runners (see the module). Empty object takes the module defaults."
  type        = any
  default     = {}
}
