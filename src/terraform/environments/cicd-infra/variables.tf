# =============================================================================
# CI/CD infrastructure - variables
# =============================================================================
# No secret is a variable. Real values (subscription and tenant IDs, names) go in
# a terraform.tfvars that stays outside the repository (*.tfvars is git-ignored).
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
  description = "GitHub runner group for the runners. Empty uses the default group."
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
  description = "The general runner: Linux, for ARM, Arc, Terraform, Ansible and OS-configuration jobs."
  type = object({
    enabled              = optional(bool, true)
    name_prefix          = optional(string, "runner-lnx")
    computer_name_prefix = optional(string, "azlrunlnx")
    count                = optional(number, 1)
    compute_type         = optional(string, "vm")
    vm_size              = optional(string, "Standard_D2s_v5")
    private_ip_addresses = optional(list(string), [])
    extra_labels         = optional(list(string), [])
    install_ansible      = optional(bool, true)
    nsg_name             = optional(string, "")
    identity_name        = optional(string, "")
  })
  default = {}
}

variable "ztp_runner" {
  description = "The ZTP runner: one Windows VM that the BMCs can reach on TCP 445, for the azurelocal-ztp Boot, Bootstrap and Vouchers stages."
  type = object({
    enabled              = optional(bool, false)
    name_prefix          = optional(string, "runner-ztp")
    computer_name_prefix = optional(string, "azlrunztp")
    vm_size              = optional(string, "Standard_D4s_v5")
    data_disk_size_gb    = optional(number, 512)
    private_ip_addresses = optional(list(string), [])
    extra_labels         = optional(list(string), [])
    nsg_name             = optional(string, "")
    identity_name        = optional(string, "")
  })
  default = {}
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
    enabled             = optional(bool, false)
    hub_vnet_id         = optional(string, "")
    use_remote_gateways = optional(bool, true)
    create_hub_side     = optional(bool, true)
    spoke_name          = optional(string, "")
    hub_name            = optional(string, "")
  })
  default = {}
}

variable "reachable_cidrs" {
  description = "The lab networks the runners reach: management, BMC, storage."
  type        = list(string)
  default     = []
}

variable "reachable_tcp_ports" {
  description = "TCP ports allowed outbound to the lab networks."
  type        = list(string)
  default     = ["22", "443", "445", "3389", "5985", "5986"]
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
  description = "Any other role assignment: { scope, role_definition_name }, keyed by a short name."
  type = map(object({
    scope                = string
    role_definition_name = string
  }))
  default = {}
}

variable "windows_admin_password_secret_name" {
  description = "Write the generated Windows administrator password to this secret in the registration vault. Empty keeps it in state only."
  type        = string
  default     = ""
}

variable "tool_versions" {
  description = "Tool versions for the runners (see the module). Empty object takes the module defaults."
  type        = any
  default     = {}
}
