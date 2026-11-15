# =============================================================================
# Networking Module — VNet, Subnets, NSGs, VPN, Bastion, NAT Gateway
# =============================================================================
# Mirrors: Implementation Part 2, Phase 4 (Stage 06) — Networking components
# Every name, SKU, resource group and setting comes from landing_zone.networks[role=hub],
# landing_zone.network_security_groups[] and landing_zone.connectivity of infrastructure.yml.
# =============================================================================

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

# -----------------------------------------------------------------------------
# Virtual Network (Hub)
# -----------------------------------------------------------------------------
resource "azurerm_virtual_network" "hub" {
  name                = var.vnet_name
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = var.vnet_address_space
  dns_servers         = var.dns_servers
  tags                = var.tags
}

# -----------------------------------------------------------------------------
# Subnets
# -----------------------------------------------------------------------------
resource "azurerm_subnet" "subnets" {
  for_each = var.subnets

  name                 = each.value.name
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [each.value.address_prefix]
}

locals {
  # The key of a subnet in var.subnets by its name (the gateway and Bastion subnets have the keys gateway and bastion).
  subnet_key_by_name = { for k, s in var.subnets : s.name => k }
}

# -----------------------------------------------------------------------------
# Network Security Groups
# -----------------------------------------------------------------------------
resource "azurerm_network_security_group" "nsgs" {
  for_each = { for nsg in var.nsgs : nsg.name => nsg }

  name                = each.value.name
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# NSG Rules — flattened from the nested nsg.rules[] structure
locals {
  nsg_rules = flatten([
    for nsg in var.nsgs : [
      for rule in nsg.rules : {
        nsg_name                   = nsg.name
        name                       = rule.name
        priority                   = rule.priority
        direction                  = rule.direction
        access                     = rule.access
        protocol                   = rule.protocol
        source_address_prefix      = rule.source_address_prefix
        destination_port_range     = rule.destination_port_range
        source_port_range          = rule.source_port_range
        destination_address_prefix = rule.destination_address_prefix
      }
    ]
  ])
}

resource "azurerm_network_security_rule" "rules" {
  for_each = { for rule in local.nsg_rules : "${rule.nsg_name}-${rule.name}" => rule }

  name                        = each.value.name
  priority                    = each.value.priority
  direction                   = each.value.direction
  access                      = each.value.access
  protocol                    = each.value.protocol
  source_port_range           = each.value.source_port_range
  destination_port_range      = each.value.destination_port_range
  source_address_prefix       = each.value.source_address_prefix
  destination_address_prefix  = each.value.destination_address_prefix
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.nsgs[each.value.nsg_name].name
}

# NSG to Subnet Associations
resource "azurerm_subnet_network_security_group_association" "associations" {
  # A subnet whose NSG is not in var.nsgs gets no association: that NSG is made elsewhere (the PowerShell scripts, for example).
  for_each = { for subnet_key, nsg_name in var.nsg_subnet_map : subnet_key => nsg_name if contains([for nsg in var.nsgs : nsg.name], nsg_name) }

  subnet_id                 = azurerm_subnet.subnets[each.key].id
  network_security_group_id = azurerm_network_security_group.nsgs[each.value].id
}

# -----------------------------------------------------------------------------
# NAT Gateway (landing_zone.connectivity.nat_gateway). Its public IP has the SKU of the
# gateway: a StandardV2 NAT gateway takes StandardV2 public IPs only, a Standard one
# Standard public IPs only (Microsoft Learn: Azure NAT Gateway SKUs,
# https://learn.microsoft.com/azure/nat-gateway/nat-sku). A Standard public IP is static
# (Microsoft Learn: Public IP addresses, SKU).
# -----------------------------------------------------------------------------
resource "azurerm_public_ip" "nat" {
  count = var.enable_nat_gateway ? 1 : 0

  name                = var.nat_config.public_ip_name
  location            = var.location
  resource_group_name = var.nat_config.resource_group
  allocation_method   = "Static"
  sku                 = var.nat_config.sku
  tags                = var.tags

  lifecycle {
    precondition {
      condition     = var.nat_config.name != "" && var.nat_config.public_ip_name != ""
      error_message = "landing_zone.connectivity.nat_gateway needs name and public_ip_name."
    }
    precondition {
      condition     = var.nat_config.network == "" || var.nat_config.network == var.vnet_name
      error_message = "landing_zone.connectivity.nat_gateway.network must be the hub network this module creates."
    }
    precondition {
      condition     = alltrue([for s in var.nat_config.subnets : contains(keys(local.subnet_key_by_name), s)])
      error_message = "Every subnet of landing_zone.connectivity.nat_gateway.subnets must be a subnet of the hub network."
    }
  }
}

resource "azurerm_nat_gateway" "main" {
  count = var.enable_nat_gateway ? 1 : 0

  name                    = var.nat_config.name
  location                = var.location
  resource_group_name     = var.nat_config.resource_group
  sku_name                = var.nat_config.sku
  idle_timeout_in_minutes = var.nat_gateway_idle_timeout
  tags                    = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "main" {
  count = var.enable_nat_gateway ? 1 : 0

  nat_gateway_id       = azurerm_nat_gateway.main[0].id
  public_ip_address_id = azurerm_public_ip.nat[0].id
}

resource "azurerm_subnet_nat_gateway_association" "main" {
  for_each = var.enable_nat_gateway ? toset(var.nat_config.subnets) : toset([])

  subnet_id      = azurerm_subnet.subnets[local.subnet_key_by_name[each.value]].id
  nat_gateway_id = azurerm_nat_gateway.main[0].id
}

# -----------------------------------------------------------------------------
# VPN Gateway (landing_zone.connectivity.vpn_gateway). A VPN gateway takes Standard SKU
# public IPs assigned as Static, two of them in active-active mode (Microsoft Learn: About
# active-active mode VPN gateways, https://learn.microsoft.com/azure/vpn-gateway/about-active-active-gateways).
# -----------------------------------------------------------------------------
locals {
  vpn_public_ip_names = var.vpn_config.active_active == true ? [var.vpn_config.public_ip_name, var.vpn_config.secondary_public_ip_name] : [var.vpn_config.public_ip_name]
}

resource "azurerm_public_ip" "vpn" {
  count = var.enable_vpn_gateway ? length(local.vpn_public_ip_names) : 0

  name                = local.vpn_public_ip_names[count.index]
  location            = var.location
  resource_group_name = var.vpn_config.resource_group
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags

  lifecycle {
    precondition {
      condition     = var.vpn_config.public_ip_name != "" && (!var.vpn_config.active_active || var.vpn_config.secondary_public_ip_name != "")
      error_message = "landing_zone.connectivity.vpn_gateway needs public_ip_name, and secondary_public_ip_name when active_active is true."
    }
    precondition {
      condition     = var.vpn_config.network == "" || var.vpn_config.network == var.vnet_name
      error_message = "landing_zone.connectivity.vpn_gateway.network must be the hub network this module creates."
    }
  }
}

# The generation follows the SKU (Microsoft Learn: VPN Gateway SKUs): VpnGw1AZ is Generation1, VpnGw2AZ and above are Generation2.
resource "azurerm_virtual_network_gateway" "vpn" {
  count = var.enable_vpn_gateway ? 1 : 0

  name                = var.vpn_config.gateway_name
  location            = var.location
  resource_group_name = var.vpn_config.resource_group
  # A VPN gateway (not ExpressRoute), route based: active-active and BGP need a route-based VPN (Microsoft Learn: About active-active mode VPN gateways).
  type          = "Vpn"
  vpn_type      = "RouteBased"
  sku           = var.vpn_config.sku
  generation    = var.vpn_config.sku == "VpnGw1AZ" ? "Generation1" : "Generation2"
  active_active = var.vpn_config.active_active
  enable_bgp    = var.vpn_config.bgp_enabled

  dynamic "ip_configuration" {
    for_each = azurerm_public_ip.vpn
    content {
      name                 = ip_configuration.key == 0 ? var.vpn_ip_configuration_name : var.vpn_secondary_ip_configuration_name
      public_ip_address_id = ip_configuration.value.id
      # Azure assigns the gateway's private address in GatewaySubnet itself.
      private_ip_address_allocation = "Dynamic"
      subnet_id                     = azurerm_subnet.subnets["gateway"].id
    }
  }

  dynamic "bgp_settings" {
    for_each = var.vpn_config.bgp_enabled ? [1] : []
    content {
      asn = var.vpn_config.bgp_asn
    }
  }

  tags = var.tags
}

# Local Network Gateway (on-premises site)
resource "azurerm_local_network_gateway" "onprem" {
  count = var.enable_vpn_gateway ? 1 : 0

  name                = var.vpn_config.local_gateway_name
  location            = var.location
  resource_group_name = var.vpn_config.resource_group
  gateway_address     = var.vpn_config.local_gateway_ip
  address_space       = var.vpn_config.local_address_prefixes

  dynamic "bgp_settings" {
    for_each = var.vpn_config.bgp_enabled && var.vpn_config.peer_asn != null ? [1] : []
    content {
      asn                 = var.vpn_config.peer_asn
      bgp_peering_address = var.vpn_config.peer_bgp_address
    }
  }

  tags = var.tags
}

# Site-to-Site VPN Connection. IPsec is the connection type of a site-to-site VPN (the other types are VNet-to-VNet and ExpressRoute).
resource "azurerm_virtual_network_gateway_connection" "s2s" {
  count = var.enable_vpn_gateway ? 1 : 0

  name                       = var.vpn_config.connection_name
  location                   = var.location
  resource_group_name        = var.vpn_config.resource_group
  type                       = "IPsec"
  virtual_network_gateway_id = azurerm_virtual_network_gateway.vpn[0].id
  local_network_gateway_id   = azurerm_local_network_gateway.onprem[0].id
  shared_key                 = var.vpn_shared_key
  enable_bgp                 = var.vpn_config.bgp_enabled
  routing_weight             = var.vpn_config.routing_weight
  tags                       = var.tags
}

# -----------------------------------------------------------------------------
# Azure Bastion (landing_zone.connectivity.bastion). Its public IP must be Standard SKU and
# Static (Microsoft Learn: About Azure Bastion configuration settings, Public IP address,
# https://learn.microsoft.com/azure/bastion/configuration-settings#public-ip-address).
# -----------------------------------------------------------------------------
resource "azurerm_public_ip" "bastion" {
  count = var.enable_bastion ? 1 : 0

  name                = var.bastion_config.public_ip_name
  location            = var.location
  resource_group_name = var.bastion_config.resource_group
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags

  lifecycle {
    precondition {
      condition     = var.bastion_config.public_ip_name != ""
      error_message = "landing_zone.connectivity.bastion needs public_ip_name."
    }
    precondition {
      condition     = var.bastion_config.network == "" || var.bastion_config.network == var.vnet_name
      error_message = "landing_zone.connectivity.bastion.network must be the hub network this module creates."
    }
  }
}

resource "azurerm_bastion_host" "main" {
  count = var.enable_bastion ? 1 : 0

  name                = var.bastion_config.name
  location            = var.location
  resource_group_name = var.bastion_config.resource_group
  sku                 = var.bastion_config.sku

  ip_configuration {
    name                 = var.bastion_ip_configuration_name
    subnet_id            = azurerm_subnet.subnets["bastion"].id
    public_ip_address_id = azurerm_public_ip.bastion[0].id
  }

  tags = var.tags
}
