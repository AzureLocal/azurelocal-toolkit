# =============================================================================
# cicd-runner module - variables
# =============================================================================
# No variable holds a secret. The runner registration credential is read from
# Key Vault by the VM at boot, through its managed identity. Only the NAME of
# the secret is a variable.
# =============================================================================

# ------------------------------------------------------------------ core ----

variable "name_prefix" {
  description = "Prefix for every resource name, for example tplabs-runner-lnx. VMs are named <name_prefix>-01, -02 and so on."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,40}$", var.name_prefix))
    error_message = "name_prefix must be 2 to 41 lowercase letters, digits or hyphens, starting with a letter or digit."
  }
}

variable "computer_name_prefix" {
  description = "Host name prefix inside the guest (Windows limits the full name to 15 characters, so the prefix is at most 12). The instance number is appended."
  type        = string
  default     = "azlrunner"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{0,11}$", var.computer_name_prefix))
    error_message = "computer_name_prefix must be 1 to 12 lowercase letters or digits, starting with a letter."
  }
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for the runners, their identity and (when created) their network."
  type        = string
}

variable "create_resource_group" {
  description = "Create the resource group. When false the group must already exist."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags for every resource."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------- runner ----

variable "os_type" {
  description = "linux or windows."
  type        = string

  validation {
    condition     = contains(["linux", "windows"], var.os_type)
    error_message = "os_type must be linux or windows."
  }
}

variable "purpose" {
  description = "general: ARM, Arc, Terraform and OS-configuration jobs. ztp: the azurelocal-ztp Boot, Bootstrap and Vouchers stages, which need a Windows host that the BMCs can reach on TCP 445."
  type        = string
  default     = "general"

  validation {
    condition     = contains(["general", "ztp"], var.purpose)
    error_message = "purpose must be general or ztp."
  }
}

variable "platform" {
  description = "Where the runner registers: github, gitlab or azure_devops (azdo is accepted as an alias)."
  type        = string

  validation {
    condition     = contains(["github", "gitlab", "azure_devops", "azdo"], var.platform)
    error_message = "platform must be github, gitlab or azure_devops."
  }
}

variable "scm_url" {
  description = "github: the organization or repository URL (https://github.com/<org> or https://github.com/<org>/<repo>). gitlab: the instance URL (https://gitlab.com). azure_devops: the organization URL (https://dev.azure.com/<org>)."
  type        = string

  validation {
    condition     = can(regex("^https://", var.scm_url))
    error_message = "scm_url must be an https:// URL."
  }
}

variable "extra_labels" {
  description = "Labels (GitHub), or Azure Pipelines capabilities, added to the defaults. Defaults: azure, the OS, terraform and ansible on Linux, and ztp for the ztp purpose. GitLab fixes tags when the runner token is created, so extra tags must be set there."
  type        = list(string)
  default     = []
}

variable "github_runner_group" {
  description = "GitHub runner group (organization runners only). Empty uses the default group. A ztp runner should have its own group."
  type        = string
  default     = ""
}

variable "azure_devops_pool" {
  description = "Azure Pipelines agent pool the agent joins. It must exist. A ztp agent should have its own pool."
  type        = string
  default     = "AzureRunners"
}

variable "registration_secret" {
  description = <<-EOT
    Where the VM reads its registration credential at boot. Only names are variables.
      key_vault_id    resource ID of the vault (the identity gets Key Vault Secrets User on it).
      key_vault_name  vault name; the VM reads https://<name>.<dns_suffix>/secrets/<secret_name>.
      secret_name     the secret.
      kind            github: pat (a PAT or App token that can create registration tokens, the default) or token (a registration token, which expires after one hour).
                      gitlab: the runner authentication token (glrt-...). azure_devops: a PAT with Agent Pools (read, manage).
      dns_suffix      vault DNS suffix, vault.azure.net unless you use a sovereign cloud.
  EOT
  type = object({
    key_vault_id   = string
    key_vault_name = string
    secret_name    = string
    kind           = optional(string, "pat")
    dns_suffix     = optional(string, "vault.azure.net")
  })

  validation {
    condition     = contains(["pat", "token"], var.registration_secret.kind)
    error_message = "registration_secret.kind must be pat or token."
  }
}

# ---------------------------------------------------------------- compute ----

variable "compute_type" {
  description = "vm (default) or vmss. A ztp runner and every Windows runner must be a vm: ZTP keeps its state on the runner's disk."
  type        = string
  default     = "vm"

  validation {
    condition     = contains(["vm", "vmss"], var.compute_type)
    error_message = "compute_type must be vm or vmss."
  }
}

variable "runner_count" {
  description = "Number of VMs, or the VM scale set capacity."
  type        = number
  default     = 1

  validation {
    condition     = var.runner_count >= 1 && var.runner_count <= 20
    error_message = "runner_count must be between 1 and 20."
  }
}

variable "vm_size" {
  description = "VM size. Docs sizing: Standard_D2s_v5 light, Standard_D4s_v5 medium and heavy."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "os_disk_size_gb" {
  description = "OS disk size in GB. 0 uses 64 on Linux and 128 on Windows."
  type        = number
  default     = 0
}

variable "os_disk_type" {
  description = "OS disk storage type."
  type        = string
  default     = "Premium_LRS"
}

variable "data_disk_size_gb" {
  description = "Data disk for the ZTP media and images (VM only). 0 adds none. On Windows the disk is initialised and mounted as the next free drive letter. Use 512 or more for the ztp purpose."
  type        = number
  default     = 0
}

variable "encryption_at_host_enabled" {
  description = "Encryption at host. The Microsoft.Compute/EncryptionAtHost feature must be registered on the subscription (task 01 does this)."
  type        = bool
  default     = false
}

variable "admin_username" {
  description = "Local administrator user name."
  type        = string
  default     = "runneradmin"
}

variable "admin_ssh_public_key" {
  description = "SSH public key for Linux (a public key, not a secret). Required for os_type linux."
  type        = string
  default     = ""
}

variable "windows_admin_password_secret_name" {
  description = "When set, the generated Windows administrator password is also written to this secret in the registration vault (the apply identity then needs Key Vault Secrets Officer). The generated password is always held in Terraform state, so protect the state backend."
  type        = string
  default     = ""
}

variable "windows_service_account" {
  description = "Account that the runner service runs as on Windows. NT AUTHORITY\\SYSTEM needs no password and is elevated, which the ztp purpose requires (SMB share, local account, firewall rule)."
  type        = string
  default     = "NT AUTHORITY\\SYSTEM"

  validation {
    condition     = contains(["NT AUTHORITY\\SYSTEM", "NT AUTHORITY\\NETWORK SERVICE", "NT AUTHORITY\\LOCAL SERVICE"], var.windows_service_account)
    error_message = "Only the well-known accounts that need no password are supported: NT AUTHORITY\\SYSTEM, NT AUTHORITY\\NETWORK SERVICE or NT AUTHORITY\\LOCAL SERVICE."
  }
}

variable "image" {
  description = "Marketplace image. Null uses Ubuntu 24.04 LTS on Linux and Windows Server 2025 Datacenter Azure Edition on Windows."
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = optional(string, "latest")
  })
  default = null
}

variable "zones" {
  description = "Availability zones for VM placement (VM scale set: the zones it spans). Empty means no zone."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------- network ----

variable "existing_subnet_id" {
  description = "Use this subnet instead of creating one. The module then creates no VNet and no peering."
  type        = string
  default     = null
}

variable "existing_vnet" {
  description = "Create the subnet in this existing VNet instead of creating a VNet. Peering is then not managed here."
  type = object({
    name                = string
    resource_group_name = string
  })
  default = null
}

variable "vnet_name" {
  description = "Name of the VNet to create (when neither existing_subnet_id nor existing_vnet is set)."
  type        = string
  default     = ""
}

variable "vnet_address_space" {
  description = "Address space of the VNet to create."
  type        = list(string)
  default     = []
}

variable "subnet_name" {
  description = "Name of the subnet to create."
  type        = string
  default     = ""
}

variable "subnet_address_prefix" {
  description = "Prefix of the subnet to create."
  type        = string
  default     = ""
}

variable "default_outbound_access_enabled" {
  description = "Azure default outbound access for the subnet. Azure stopped granting it to new subnets in September 2025; true keeps HTTPS outbound without a NAT gateway. Replace with a NAT gateway or firewall route when you have one."
  type        = bool
  default     = true
}

variable "associate_nsg_with_existing_subnet" {
  description = "Attach the module's NSG to existing_subnet_id. Leave false when the subnet already has an NSG you own."
  type        = bool
  default     = false
}

variable "private_ip_addresses" {
  description = "Static private IPs for the VMs, in order (VM only). Empty uses dynamic addresses."
  type        = list(string)
  default     = []
}

variable "dns_servers" {
  description = "DNS servers for a VNet the module creates. Empty uses Azure DNS."
  type        = list(string)
  default     = []
}

variable "hub_peering" {
  description = <<-EOT
    Peer the VNet the module creates with a hub VNet.
      hub_vnet_id          resource ID of the hub VNet.
      use_remote_gateways  use the hub's VPN or ExpressRoute gateway (the hub side then allows gateway transit).
      create_hub_side      create the hub half of the peering (needs rights in the hub subscription). Set false when the network team owns it.
  EOT
  type = object({
    enabled             = optional(bool, false)
    hub_vnet_id         = optional(string, "")
    use_remote_gateways = optional(bool, true)
    create_hub_side     = optional(bool, true)
  })
  default = {}

  validation {
    condition     = !var.hub_peering.enabled || can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Network/virtualNetworks/[^/]+$", var.hub_peering.hub_vnet_id))
    error_message = "hub_peering.hub_vnet_id must be the resource ID of a virtual network when hub_peering.enabled is true."
  }
}

variable "reachable_cidrs" {
  description = "Networks the runner reaches over the peering or tunnel (the lab management, BMC and storage ranges). Outbound is allowed to these on reachable_tcp_ports plus ICMP."
  type        = list(string)
  default     = []
}

variable "reachable_tcp_ports" {
  description = "TCP ports allowed outbound to reachable_cidrs: SSH, HTTPS (BMC), SMB, RDP, WinRM and the ZTP maintenance environment."
  type        = list(string)
  default     = ["22", "443", "445", "3389", "5985", "5986"]
}

variable "bmc_cidrs" {
  description = "The BMC (iDRAC) networks. For the ztp purpose the NSG allows inbound TCP 445 from these ranges and nothing else inbound. Required for ztp."
  type        = list(string)
  default     = []
}

variable "admin_source_cidrs" {
  description = "Ranges allowed to reach SSH (22) or RDP (3389) on the runner. Empty allows no inbound administration."
  type        = list(string)
  default     = []
}

# --------------------------------------------------------------- identity ----

variable "managed_identity_name" {
  description = "User-assigned managed identity name. Empty uses id-<name_prefix>."
  type        = string
  default     = ""
}

variable "contributor_scopes" {
  description = "Scopes (resource groups, rarely a subscription) where the runner is Contributor: the Azure Local resource group, and its managed-resources group."
  type        = list(string)
  default     = []
}

variable "rbac_administrator_scopes" {
  description = "Scopes where the runner is Role Based Access Control Administrator (the Azure Local deployment and ZTP assign roles). Use resource groups, not the subscription."
  type        = list(string)
  default     = []
}

variable "rbac_administrator_delegable_role_ids" {
  description = "Role definition GUIDs that the runner may assign and remove under rbac_administrator_scopes. Empty allows any role (what Microsoft's prerequisite for simplified provisioning grants). A list restricts the assignment with an ABAC condition."
  type        = list(string)
  default     = []
}

variable "arc_machine_scopes" {
  description = "Scopes where the runner is Azure Connected Machine Resource Administrator, so it can run Arc Run Command on the Azure Local machines."
  type        = list(string)
  default     = []
}

variable "key_vault_reader_ids" {
  description = "Extra vaults (resource IDs) where the runner reads secrets (Key Vault Secrets User): the BMC, provisioning and deployment administrator vaults. The registration vault is always included."
  type        = list(string)
  default     = []
}

variable "additional_role_assignments" {
  description = "Any other assignment, keyed by a short name: { scope, role_definition_name }."
  type = map(object({
    scope                = string
    role_definition_name = string
  }))
  default = {}
}

# ---------------------------------------------------------------- tooling ----

variable "install_ansible" {
  description = "Install ansible-core, ansible-lint, pywinrm and the toolkit's collections on a Linux runner."
  type        = bool
  default     = true
}

variable "ansible_collections" {
  description = "Ansible collections installed on a Linux runner. Mirrors src/ansible/collections/requirements.yml."
  type        = list(string)
  default     = ["azure.azcollection", "microsoft.ad", "ansible.windows", "community.windows", "community.general"]
}

variable "tool_versions" {
  description = "Tool versions. Empty strings take the current release (Azure CLI, PowerShell, Az, the Azure Pipelines agent). SHA-256 values are checked when set."
  type = object({
    terraform                    = optional(string, "1.16.3")
    bicep                        = optional(string, "0.49.2")
    bicep_linux_sha256           = optional(string, "0ab9de90c2493f206f8281bae74f9ee2d5ed3605548dab1adf41fef185e1f7c5")
    bicep_windows_sha256         = optional(string, "")
    github_runner                = optional(string, "2.338.2")
    github_runner_sha256         = optional(string, "baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40")
    github_runner_windows_sha256 = optional(string, "")
    gitlab_runner                = optional(string, "19.5.3")
    gitlab_runner_sha256         = optional(string, "cd586a217b0ba4d339b3f3d645b84f8f5e1cc711e73148c30a3eec0f8c78378b")
    gitlab_runner_windows_sha256 = optional(string, "")
    azure_devops_agent           = optional(string, "")
    az_powershell                = optional(string, "")
    ansible_core                 = optional(string, "")
  })
  default = {}
}

variable "bootstrap_timeout_seconds" {
  description = "How long Terraform waits for the Windows bootstrap (Run Command) to finish."
  type        = number
  default     = 3600
}
