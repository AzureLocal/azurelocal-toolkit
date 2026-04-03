# =============================================================================
# Networking Module — VNet, Subnets, NSGs, VPN, Bastion, NAT Gateway
# =============================================================================
# Mirrors: Implementation Part 2, Phase 4 (Stage 06) — Networking components
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

# -----------------------------------------------------------------------------
# Network Security Groups — dynamically generated from variables.yml
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
        source_port_range          = lookup(rule, "source_port_range", "*")
        destination_address_prefix = lookup(rule, "destination_address_prefix", "*")
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
  for_each = var.nsg_subnet_map

  subnet_id                 = azurerm_subnet.subnets[each.key].id
  network_security_group_id = azurerm_network_security_group.nsgs[each.value].id
}

# -----------------------------------------------------------------------------
# NAT Gateway
# -----------------------------------------------------------------------------
resource "azurerm_public_ip" "nat" {
  count = var.enable_nat_gateway ? 1 : 0

  name                = "pip-${var.org_code}-natgw-01"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "main" {
  count = var.enable_nat_gateway ? 1 : 0

  name                    = "natgw-${var.org_code}-01"
  location                = var.location
  resource_group_name     = var.resource_group_name
  sku_name                = "Standard"
  idle_timeout_in_minutes = var.nat_gateway_idle_timeout
  tags                    = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "main" {
  count = var.enable_nat_gateway ? 1 : 0

  nat_gateway_id       = azurerm_nat_gateway.main[0].id
  public_ip_address_id = azurerm_public_ip.nat[0].id
}

# -----------------------------------------------------------------------------
# VPN Gateway
# -----------------------------------------------------------------------------
resource "azurerm_public_ip" "vpn" {
  count = var.enable_vpn_gateway ? 1 : 0

  name                = var.vpn_config.public_ip_name
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_virtual_network_gateway" "vpn" {
  count = var.enable_vpn_gateway ? 1 : 0

  name                = var.vpn_config.gateway_name
  location            = var.location
  resource_group_name = var.resource_group_name
  type                = "Vpn"
  vpn_type            = "RouteBased"
  sku                 = var.vpn_config.sku
  generation          = var.vpn_config.generation
  active_active       = var.vpn_config.active_active
  enable_bgp          = var.vpn_config.bgp_enabled

  ip_configuration {
    name                          = "vnetGatewayConfig"
    public_ip_address_id          = azurerm_public_ip.vpn[0].id
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = azurerm_subnet.subnets["gateway"].id
  }

  tags = var.tags
}

# Local Network Gateway (on-premises site)
resource "azurerm_local_network_gateway" "onprem" {
  count = var.enable_vpn_gateway ? 1 : 0

  name                = var.vpn_config.local_gateway_name
  location            = var.location
  resource_group_name = var.resource_group_name
  gateway_address     = var.vpn_config.local_gateway_ip
  address_space       = var.vpn_config.local_address_prefixes
  tags                = var.tags
}

# Site-to-Site VPN Connection
resource "azurerm_virtual_network_gateway_connection" "s2s" {
  count = var.enable_vpn_gateway ? 1 : 0

  name                       = var.vpn_config.connection_name
  location                   = var.location
  resource_group_name        = var.resource_group_name
  type                       = "IPsec"
  virtual_network_gateway_id = azurerm_virtual_network_gateway.vpn[0].id
  local_network_gateway_id   = azurerm_local_network_gateway.onprem[0].id
  shared_key                 = var.vpn_shared_key
  enable_bgp                 = var.vpn_config.bgp_enabled
  routing_weight             = var.vpn_config.routing_weight
  tags                       = var.tags
}

# -----------------------------------------------------------------------------
# Azure Bastion
# -----------------------------------------------------------------------------
resource "azurerm_public_ip" "bastion" {
  count = var.enable_bastion ? 1 : 0

  name                = var.bastion_config.public_ip_name
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_bastion_host" "main" {
  count = var.enable_bastion ? 1 : 0

  name                = var.bastion_config.name
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = var.bastion_config.sku

  ip_configuration {
    name                 = "bastionIpConfig"
    subnet_id            = azurerm_subnet.subnets["bastion"].id
    public_ip_address_id = azurerm_public_ip.bastion[0].id
  }

  tags = var.tags
}
