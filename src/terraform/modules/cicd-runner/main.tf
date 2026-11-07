# =============================================================================
# cicd-runner module - resource group, identity, network, NSG, role assignments
# =============================================================================
# Self-hosted CI/CD runners on Azure VMs (or a VM scale set), Linux or Windows,
# for GitHub Actions, GitLab CI/CD or Azure Pipelines. See compute.tf for the
# machines and templates/ for what runs at first boot.
# =============================================================================

locals {
  platform   = var.platform == "azdo" ? "azure_devops" : var.platform
  is_windows = var.os_type == "windows"
  is_ztp     = var.purpose == "ztp"
  use_vm     = var.compute_type == "vm"
  use_vmss   = var.compute_type == "vmss"

  default_labels = concat(
    ["azure", var.os_type],
    local.is_windows ? [] : ["terraform", "ansible"],
    local.is_ztp ? ["ztp"] : [],
  )
  labels = distinct(concat(local.default_labels, var.extra_labels))

  create_vnet   = var.existing_subnet_id == null && var.existing_vnet == null
  create_subnet = var.existing_subnet_id == null

  vnet_name           = local.create_vnet ? var.vnet_name : try(var.existing_vnet.name, null)
  vnet_resource_group = local.create_vnet ? local.resource_group_name : try(var.existing_vnet.resource_group_name, null)

  # BMC networks are always reachable outbound (Redfish on 443) for the ztp purpose.
  outbound_cidrs = distinct(concat(var.reachable_cidrs, var.bmc_cidrs))

  instance_names = [for i in range(var.runner_count) : format("%s-%02d", var.name_prefix, i + 1)]
  instances = {
    for i, n in local.instance_names : n => {
      index         = i
      computer_name = format("%s%02d", var.computer_name_prefix, i + 1)
    }
  }

  tags = merge(var.tags, { "managed-by" = "azurelocal-toolkit/cicd-runner" })

  # ABAC condition that limits which roles the runner may assign (constrained delegation).
  delegable_ids = join(", ", var.rbac_administrator_delegable_role_ids)
  rbac_condition = length(var.rbac_administrator_delegable_role_ids) == 0 ? null : join("", [
    "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR ",
    "(@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${local.delegable_ids}})) AND ",
    "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR ",
    "(@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${local.delegable_ids}}))",
  ])

  role_assignments = merge(
    { for i, s in var.contributor_scopes : "contributor-${i}" => {
      scope       = s, role = "Contributor", condition = null
      description = "CI/CD runner ${var.name_prefix}: deploys and configures resources in this scope."
    } },
    { for i, s in var.rbac_administrator_scopes : "rbac-admin-${i}" => {
      scope       = s, role = "Role Based Access Control Administrator", condition = local.rbac_condition
      description = "CI/CD runner ${var.name_prefix}: assigns the roles that the Azure Local deployment needs, in this scope only."
    } },
    { for i, s in var.arc_machine_scopes : "arc-machine-${i}" => {
      scope       = s, role = "Azure Connected Machine Resource Administrator", condition = null
      description = "CI/CD runner ${var.name_prefix}: Arc Run Command on the machines in this scope."
    } },
    { for i, s in distinct(concat([var.registration_secret.key_vault_id], var.key_vault_reader_ids)) : "key-vault-${i}" => {
      scope       = s, role = "Key Vault Secrets User", condition = null
      description = "CI/CD runner ${var.name_prefix}: reads its registration credential and lab secrets."
    } },
    { for k, v in var.additional_role_assignments : "extra-${k}" => {
      scope       = v.scope, role = v.role_definition_name, condition = null
      description = "CI/CD runner ${var.name_prefix}: ${k}."
    } },
  )
}

# -----------------------------------------------------------------------------
# Resource group
# -----------------------------------------------------------------------------
resource "azurerm_resource_group" "this" {
  count = var.create_resource_group ? 1 : 0

  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

data "azurerm_resource_group" "this" {
  count = var.create_resource_group ? 0 : 1

  name = var.resource_group_name
}

locals {
  resource_group_name = coalesce(one(azurerm_resource_group.this[*].name), one(data.azurerm_resource_group.this[*].name))
}

# -----------------------------------------------------------------------------
# Identity. The runner signs in to Azure as this identity. It also reads its
# registration credential from Key Vault with it.
# -----------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "this" {
  name                = var.managed_identity_name != "" ? var.managed_identity_name : "id-${var.name_prefix}"
  location            = var.location
  resource_group_name = local.resource_group_name
  tags                = local.tags

  # Every other resource depends on the identity, so the input checks live here.
  lifecycle {
    precondition {
      condition     = !local.is_windows || local.use_vm
      error_message = "Windows runners must use compute_type = \"vm\". The Windows bootstrap runs through Run Command, which VM scale sets do not support."
    }
    precondition {
      condition     = !local.is_ztp || (local.is_windows && local.use_vm)
      error_message = "purpose = \"ztp\" needs os_type = \"windows\" and compute_type = \"vm\": ZTP shares images over SMB with Windows commands and keeps its state on the runner's disk."
    }
    precondition {
      condition     = !local.is_ztp || length(var.bmc_cidrs) > 0
      error_message = "purpose = \"ztp\" needs bmc_cidrs: the NSG allows inbound TCP 445 from those ranges only."
    }
    precondition {
      condition     = local.is_windows || length(var.admin_ssh_public_key) > 0
      error_message = "A Linux runner needs admin_ssh_public_key."
    }
    precondition {
      condition     = !local.create_vnet || (var.vnet_name != "" && length(var.vnet_address_space) > 0)
      error_message = "vnet_name and vnet_address_space are needed when the module creates the VNet."
    }
    precondition {
      condition     = !local.create_subnet || (var.subnet_name != "" && var.subnet_address_prefix != "")
      error_message = "subnet_name and subnet_address_prefix are needed when the module creates the subnet."
    }
    precondition {
      condition     = local.use_vm || var.data_disk_size_gb == 0
      error_message = "data_disk_size_gb is supported for compute_type = \"vm\" only."
    }
  }
}

resource "azurerm_role_assignment" "this" {
  for_each = local.role_assignments

  scope                            = each.value.scope
  role_definition_name             = each.value.role
  principal_id                     = azurerm_user_assigned_identity.this.principal_id
  principal_type                   = "ServicePrincipal"
  description                      = each.value.description
  condition                        = each.value.condition
  condition_version                = each.value.condition == null ? null : "2.0"
  skip_service_principal_aad_check = true
}

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------
resource "azurerm_virtual_network" "this" {
  count = local.create_vnet ? 1 : 0

  name                = var.vnet_name
  location            = var.location
  resource_group_name = local.resource_group_name
  address_space       = var.vnet_address_space
  dns_servers         = length(var.dns_servers) > 0 ? var.dns_servers : null
  tags                = local.tags

  depends_on = [azurerm_user_assigned_identity.this]
}

resource "azurerm_subnet" "this" {
  count = local.create_subnet ? 1 : 0

  name                            = var.subnet_name
  resource_group_name             = local.vnet_resource_group
  virtual_network_name            = local.create_vnet ? azurerm_virtual_network.this[0].name : var.existing_vnet.name
  address_prefixes                = [var.subnet_address_prefix]
  default_outbound_access_enabled = var.default_outbound_access_enabled

  depends_on = [azurerm_user_assigned_identity.this]
}

locals {
  subnet_id = var.existing_subnet_id != null ? var.existing_subnet_id : azurerm_subnet.this[0].id
}

# Spoke side of the hub peering (the VNet this module creates).
resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  count = local.create_vnet && var.hub_peering.enabled ? 1 : 0

  name                         = var.hub_peering.spoke_name != "" ? var.hub_peering.spoke_name : "peer-${var.vnet_name}-to-hub"
  resource_group_name          = local.resource_group_name
  virtual_network_name         = azurerm_virtual_network.this[0].name
  remote_virtual_network_id    = var.hub_peering.hub_vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  use_remote_gateways          = var.hub_peering.use_remote_gateways

  # The hub must allow gateway transit before the spoke may use its gateway.
  depends_on = [azurerm_virtual_network_peering.hub_to_spoke]
}

# Hub side. The hub subscription's provider creates it, unless the network team owns it.
resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  provider = azurerm.hub
  count    = local.create_vnet && var.hub_peering.enabled && var.hub_peering.create_hub_side ? 1 : 0

  name                         = var.hub_peering.hub_name != "" ? var.hub_peering.hub_name : "peer-hub-to-${var.vnet_name}"
  resource_group_name          = split("/", var.hub_peering.hub_vnet_id)[4]
  virtual_network_name         = split("/", var.hub_peering.hub_vnet_id)[8]
  remote_virtual_network_id    = azurerm_virtual_network.this[0].id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = var.hub_peering.use_remote_gateways
}

# -----------------------------------------------------------------------------
# NSG. Nothing inbound except, for the ztp purpose, TCP 445 from the BMC ranges
# and, when you list them, administration from admin_source_cidrs.
# Outbound: Azure, package and runner downloads (HTTPS, HTTP), the lab ranges.
# -----------------------------------------------------------------------------
resource "azurerm_network_security_group" "this" {
  name                = var.nsg_name != "" ? var.nsg_name : "nsg-${var.name_prefix}"
  location            = var.location
  resource_group_name = local.resource_group_name
  tags                = local.tags

  depends_on = [azurerm_user_assigned_identity.this]
}

locals {
  admin_port = local.is_windows ? "3389" : "22"

  nsg_rules = merge(
    {
      "Deny-Inbound-Internet" = {
        priority        = 4000, direction = "Inbound", access = "Deny", protocol = "*"
        source_prefixes = ["Internet"], dest_prefixes = ["*"], ports = ["*"]
        description     = "Nothing from the internet."
      }
      "Allow-Outbound-AzurePlatform" = {
        priority        = 100, direction = "Outbound", access = "Allow", protocol = "*"
        source_prefixes = ["*"], dest_prefixes = ["168.63.129.16"], ports = ["*"]
        description     = "Azure DNS, wireserver and health probe address."
      }
      "Allow-Outbound-HTTPS-AzureCloud" = {
        priority        = 110, direction = "Outbound", access = "Allow", protocol = "Tcp"
        source_prefixes = ["*"], dest_prefixes = ["AzureCloud"], ports = ["443"]
        description     = "ARM, Entra ID, Key Vault."
      }
      "Allow-Outbound-HTTPS-Internet" = {
        priority        = 120, direction = "Outbound", access = "Allow", protocol = "Tcp"
        source_prefixes = ["*"], dest_prefixes = ["Internet"], ports = ["443"]
        description     = "GitHub, GitLab, Azure DevOps, package repositories and runner downloads."
      }
      "Allow-Outbound-HTTP-Internet" = {
        priority        = 130, direction = "Outbound", access = "Allow", protocol = "Tcp"
        source_prefixes = ["*"], dest_prefixes = ["Internet"], ports = ["80"]
        description     = "Package mirrors (signed metadata)."
      }
      "Deny-Outbound-Other" = {
        priority        = 4000, direction = "Outbound", access = "Deny", protocol = "*"
        source_prefixes = ["*"], dest_prefixes = ["*"], ports = ["*"]
        description     = "Everything not listed above."
      }
    },
    length(local.outbound_cidrs) == 0 ? {} : {
      "Allow-Outbound-Lab-Tcp" = {
        priority        = 200, direction = "Outbound", access = "Allow", protocol = "Tcp"
        source_prefixes = ["*"], dest_prefixes = local.outbound_cidrs, ports = var.reachable_tcp_ports
        description     = "The lab over the peering or tunnel."
      }
      "Allow-Outbound-Lab-Icmp" = {
        priority        = 210, direction = "Outbound", access = "Allow", protocol = "Icmp"
        source_prefixes = ["*"], dest_prefixes = local.outbound_cidrs, ports = ["*"]
        description     = "Reachability checks."
      }
    },
    !local.is_ztp ? {} : {
      "Allow-Inbound-BMC-SMB" = {
        priority        = 100, direction = "Inbound", access = "Allow", protocol = "Tcp"
        source_prefixes = var.bmc_cidrs, dest_prefixes = ["*"], ports = ["445"]
        description     = "The BMC's SMB client reads and writes the virtual USB image on the runner."
      }
    },
    length(var.admin_source_cidrs) == 0 ? {} : {
      "Allow-Inbound-Admin" = {
        priority        = 110, direction = "Inbound", access = "Allow", protocol = "Tcp"
        source_prefixes = var.admin_source_cidrs, dest_prefixes = ["*"], ports = [local.admin_port]
        description     = "Administration from the listed ranges."
      }
    },
  )
}

resource "azurerm_network_security_rule" "this" {
  for_each = local.nsg_rules

  name                         = each.key
  priority                     = each.value.priority
  direction                    = each.value.direction
  access                       = each.value.access
  protocol                     = each.value.protocol
  source_port_range            = "*"
  source_address_prefix        = length(each.value.source_prefixes) == 1 ? each.value.source_prefixes[0] : null
  source_address_prefixes      = length(each.value.source_prefixes) > 1 ? each.value.source_prefixes : null
  destination_address_prefix   = length(each.value.dest_prefixes) == 1 ? each.value.dest_prefixes[0] : null
  destination_address_prefixes = length(each.value.dest_prefixes) > 1 ? each.value.dest_prefixes : null
  destination_port_range       = length(each.value.ports) == 1 ? each.value.ports[0] : null
  destination_port_ranges      = length(each.value.ports) > 1 ? each.value.ports : null
  description                  = each.value.description
  resource_group_name          = local.resource_group_name
  network_security_group_name  = azurerm_network_security_group.this.name
}

resource "azurerm_subnet_network_security_group_association" "this" {
  count = local.create_subnet || var.associate_nsg_with_existing_subnet ? 1 : 0

  subnet_id                 = local.subnet_id
  network_security_group_id = azurerm_network_security_group.this.id

  depends_on = [azurerm_network_security_rule.this]
}
