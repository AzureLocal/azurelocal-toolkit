# =============================================================================
# cicd-runner module - variables
# =============================================================================
# No variable holds a secret. The runner registration credential is read from
# Key Vault by the VM at boot, through its managed identity. Only the NAME of
# the secret is a variable.
# =============================================================================

# ------------------------------------------------------------------ core ----

variable "name_prefix" {
  description = "Prefix for every resource name, for example iic-runner-lnx. VMs are named <name_prefix>-01, -02 and so on."
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

variable "base_labels" {
  description = "Labels every runner carries, before its OS (the second default label)."
  type        = list(string)
  default     = ["azure"]
}

variable "linux_labels" {
  description = "Labels a Linux runner carries for the tools it has."
  type        = list(string)
  default     = ["terraform", "ansible"]
}

variable "ztp_labels" {
  description = "Labels a runner of the ztp purpose carries."
  type        = list(string)
  default     = ["ztp"]
}

variable "github_runner_group" {
  description = "GitHub runner group (organization runners only). Empty uses the default group. A ztp runner should have its own group."
  type        = string
  default     = ""
}

variable "azure_devops_pool" {
  description = "Azure Pipelines agent pool the agent joins (devops.runners[].pool). It must exist. A ztp agent should have its own pool. Needed when platform is azure_devops; there is no default pool."
  type        = string
  default     = ""
}

variable "registration_secret" {
  description = <<-EOT
    Where the VM reads its registration credential at boot. Only names are variables.
      key_vault_id    resource ID of the vault (the identity gets Key Vault Secrets User on it).
      key_vault_name  vault name; the VM reads https://<name>.<dns_suffix>/secrets/<secret_name>.
      secret_name     the secret.
      kind            github: pat (a PAT or App token that can create registration tokens, the default) or token (a registration token, which expires after one hour).
                      gitlab: the runner authentication token (glrt-...). azure_devops: a PAT with Agent Pools (read, manage).
      dns_suffix      vault DNS suffix of the cloud (the class c default is the Azure public cloud's).
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
  description = "vm or vmss (devops.runners[].compute_type). A ztp runner and every Windows runner must be a vm: ZTP keeps its state on the runner's disk."
  type        = string

  validation {
    condition     = contains(["vm", "vmss"], var.compute_type)
    error_message = "compute_type must be vm or vmss."
  }
}

variable "runner_count" {
  description = "Number of VMs, or the VM scale set capacity (devops.runners[].count)."
  type        = number

  validation {
    condition     = var.runner_count >= 1 && var.runner_count <= 20
    error_message = "runner_count must be between 1 and 20."
  }
}

variable "vm_size" {
  description = "VM size (devops.runners[].size)."
  type        = string
}

variable "os_disk_size_gb" {
  description = "OS disk size in GB (devops.runners[].os_disk_size_gb). Null takes the size of the OS in default_os_disk_size_gb."
  type        = number
  default     = null
}

variable "default_os_disk_size_gb" {
  description = "OS disk size in GB by os_type when devops.runners[].os_disk_size_gb is not set."
  type        = map(number)
  default = {
    linux   = 64
    windows = 128
  }
}

variable "os_disk_type" {
  description = "Storage type of the OS and data disks (devops.runners[].os_disk_type)."
  type        = string
}

variable "os_disk_caching" {
  description = "Caching of the OS disk: None, ReadOnly or ReadWrite (devops.runners[].os_disk_caching)."
  type        = string
}

variable "data_disk_caching" {
  description = "Caching of the data disk: None, ReadOnly or ReadWrite (devops.runners[].data_disk_caching)."
  type        = string
}

variable "data_disk_size_gb" {
  description = "Data disk for the ZTP media and images (VM only). 0 adds none. On Windows the disk is initialised and mounted as the next free drive letter. Use 512 or more for the ztp purpose."
  type        = number
  default     = 0
}

variable "encryption_at_host_enabled" {
  description = "Encryption at host (devops.runners[].encryption_at_host). The Microsoft.Compute/EncryptionAtHost feature must be registered on the subscription (task 01 does this)."
  type        = bool
}

variable "admin_username" {
  description = "Local administrator user name (devops.runners[].admin_username)."
  type        = string
}

variable "disable_password_authentication" {
  description = "A Linux runner signs in with the SSH key only."
  type        = bool
  default     = true
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

variable "windows_root" {
  description = "Folder on a Windows runner that holds the runner, the agent, the logs and the state: <root>\\actions-runner, <root>\\GitLab-Runner, <root>\\azagent, <root>\\logs, <root>\\state. The same value as cicd_runner_windows_root of the Ansible cicd_runner role."
  type        = string
  default     = "C:\\azl"
}

variable "image" {
  description = "Marketplace image (devops.runners[].image). Null takes the image of the OS in default_images."
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })
  default = null
}

variable "default_images" {
  description = "Marketplace image by os_type when devops.runners[].image is not set: Ubuntu 24.04 LTS on Linux and Windows Server 2025 Datacenter Azure Edition on Windows."
  type = map(object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  }))
  default = {
    linux   = { publisher = "Canonical", offer = "ubuntu-24_04-lts", sku = "server", version = "latest" }
    windows = { publisher = "MicrosoftWindowsServer", offer = "WindowsServer", sku = "2025-datacenter-azure-edition", version = "latest" }
  }
}

variable "zones" {
  description = "Availability zones for VM placement (VM scale set: the zones it spans), devops.runners[].zones. Empty means no zone."
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
      spoke_name, hub_name names of the two peerings (devops.runner_network.hub_peering.spoke_name and hub_name).
      allow_forwarded_traffic, allow_gateway_transit  the peering options of the hub network (landing_zone.networks[].allow_forwarded_traffic and allow_gateway_transit).
  EOT
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
  description = "TCP ports allowed outbound to reachable_cidrs (devops.runner_network.reachable_tcp_ports)."
  type        = list(string)
}

variable "allow_internet_https" {
  description = "Allow HTTPS (443) outbound to the internet: GitHub, GitLab, Azure DevOps, package repositories and runner downloads (devops.runner_network.allow_internet_https)."
  type        = bool
}

variable "allow_internet_http" {
  description = "Allow HTTP (80) outbound to the internet: package mirrors with signed metadata (devops.runner_network.allow_internet_http)."
  type        = bool
}

variable "allow_icmp" {
  description = "Allow ICMP outbound to the lab networks, for reachability checks (devops.runner_network.allow_icmp)."
  type        = bool
}

variable "peering_allow_virtual_network_access" {
  description = "Both peerings let the two VNets reach each other: the point of the peering."
  type        = bool
  default     = true
}

variable "nsg_rule_settings" {
  description = "Name and priority of each rule of the runner NSG, by its role."
  type = map(object({
    name     = string
    priority = number
  }))
  default = {
    deny_inbound_internet            = { name = "Deny-Inbound-Internet", priority = 4000 }
    allow_outbound_azure_platform    = { name = "Allow-Outbound-AzurePlatform", priority = 100 }
    allow_outbound_https_azure_cloud = { name = "Allow-Outbound-HTTPS-AzureCloud", priority = 110 }
    allow_outbound_https_internet    = { name = "Allow-Outbound-HTTPS-Internet", priority = 120 }
    allow_outbound_http_internet     = { name = "Allow-Outbound-HTTP-Internet", priority = 130 }
    deny_outbound_other              = { name = "Deny-Outbound-Other", priority = 4000 }
    allow_outbound_lab_tcp           = { name = "Allow-Outbound-Lab-Tcp", priority = 200 }
    allow_outbound_lab_icmp          = { name = "Allow-Outbound-Lab-Icmp", priority = 210 }
    allow_inbound_bmc_smb            = { name = "Allow-Inbound-BMC-SMB", priority = 100 }
    allow_inbound_admin              = { name = "Allow-Inbound-Admin", priority = 110 }
  }
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

variable "nsg_name" {
  description = "Network security group name (devops.runners[].nsg_name). Set it to an existing group's name to adopt it with terraform import."
  type        = string

  validation {
    condition     = var.nsg_name != ""
    error_message = "nsg_name is needed (devops.runners[].nsg_name)."
  }
}

variable "managed_identity_name" {
  description = "User-assigned managed identity name (devops.runners[].managed_identity_name)."
  type        = string

  validation {
    condition     = var.managed_identity_name != ""
    error_message = "managed_identity_name is needed (devops.runners[].managed_identity_name)."
  }
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

variable "instance_name_format" {
  description = "Format of a VM name: the name prefix and the instance number (format())."
  type        = string
  default     = "%s-%02d"
}

variable "computer_name_format" {
  description = "Format of the host name inside the guest: the computer name prefix and the instance number (format())."
  type        = string
  default     = "%s%02d"
}

variable "module_tags" {
  description = "Tags this module adds to every resource, on top of tags."
  type        = map(string)
  default = {
    "managed-by" = "azurelocal-toolkit/cicd-runner"
  }
}

variable "nic_name_prefix" {
  description = "Prefix of the name of each VM network interface; the VM name follows it."
  type        = string
  default     = "nic-"
}

variable "data_disk_name_prefix" {
  description = "Prefix of the name of each data disk; the VM name follows it."
  type        = string
  default     = "disk-data-"
}

variable "vmss_nic_name" {
  description = "Name of the network interface of the VM scale set profile."
  type        = string
  default     = "nic"
}

variable "ip_configuration_name" {
  description = "Name of the IP configuration of each network interface."
  type        = string
  default     = "internal"
}

variable "boot_diagnostics_enabled" {
  description = "Boot diagnostics with a managed storage account on each machine."
  type        = bool
  default     = true
}

variable "vmss_upgrade_mode" {
  description = "Upgrade mode of the VM scale set: Manual, the runners are replaced by a new apply."
  type        = string
  default     = "Manual"
}

variable "bootstrap_run_command_name" {
  description = "Name of the Run Command that bootstraps a Windows runner."
  type        = string
  default     = "azl-runner-bootstrap"
}

variable "secret_content_type" {
  description = "Content type of the Windows administrator password secret in Key Vault."
  type        = string
  default     = "text/plain"
}

variable "windows_password_policy" {
  description = "Length and character classes of the generated Windows administrator password."
  type = object({
    length             = number
    special_characters = string
    min_upper          = number
    min_lower          = number
    min_numeric        = number
    min_special        = number
  })
  default = {
    length             = 28
    special_characters = "!#%*()-_=+[]"
    min_upper          = 2
    min_lower          = 2
    min_numeric        = 2
    min_special        = 2
  }
}
