# =============================================================================
# Azure Local — Root Module
# =============================================================================
# Orchestrates all child modules in dependency order for a complete
# Azure Local foundation deployment.
#
# Order: landing-zone → networking → identity → monitoring → security → compute
# =============================================================================

# -----------------------------------------------------------------------------
# Phase 1: Landing Zone — Management Groups & Resource Groups
# -----------------------------------------------------------------------------
module "landing_zone" {
  source = "../../modules/landing-zone"

  management_groups = var.management_groups
  subscriptions     = var.subscriptions
  resource_groups   = var.resource_groups
  location          = var.location
  tags              = var.tags
}

# -----------------------------------------------------------------------------
# Phase 2: Networking — VNet, Subnets, NSGs, VPN, Bastion, NAT gateway
# -----------------------------------------------------------------------------
locals {
  # A NAT gateway, VPN gateway or Bastion host with no resource group of its own goes in the resource group of the hub network
  # (the registry description of landing_zone.connectivity.*.resource_group).
  hub_resource_group = module.landing_zone.resource_group_names[var.hub_resource_group_name]
}

module "networking" {
  source = "../../modules/networking"

  vnet_name           = var.vnet_name
  vnet_address_space  = var.vnet_address_space
  location            = var.location
  resource_group_name = local.hub_resource_group
  dns_servers         = var.dns_servers
  subnets             = var.subnets
  nsgs                = var.nsgs
  nsg_subnet_map      = var.nsg_subnet_map

  enable_nat_gateway       = var.enable_nat_gateway
  nat_gateway_idle_timeout = var.nat_gateway_idle_timeout
  nat_config               = merge(var.nat_config, { resource_group = var.nat_config.resource_group != "" ? var.nat_config.resource_group : local.hub_resource_group })

  enable_vpn_gateway = var.enable_vpn_gateway
  vpn_config         = merge(var.vpn_config, { resource_group = var.vpn_config.resource_group != "" ? var.vpn_config.resource_group : local.hub_resource_group })
  vpn_shared_key     = var.vpn_shared_key

  enable_bastion = var.enable_bastion
  bastion_config = merge(var.bastion_config, { resource_group = var.bastion_config.resource_group != "" ? var.bastion_config.resource_group : local.hub_resource_group })

  tags = var.tags

  depends_on = [module.landing_zone]
}

# -----------------------------------------------------------------------------
# Phase 3: Monitoring — Log Analytics workspace and action group (created before Identity for diagnostics)
# -----------------------------------------------------------------------------
module "monitoring" {
  source = "../../modules/monitoring"

  workspace_name        = var.log_analytics_workspace_name
  location              = var.location
  resource_group_name   = module.landing_zone.resource_group_names[var.monitoring_resource_group_name]
  action_group_name     = var.action_group_name
  sku                   = var.log_analytics_sku
  retention_days        = var.log_analytics_retention_days
  alert_email_addresses = var.alert_email_addresses

  tags = var.tags

  depends_on = [module.landing_zone]
}

# -----------------------------------------------------------------------------
# Phase 4: Identity — Key Vault, RBAC, Managed Identities
# -----------------------------------------------------------------------------
module "identity" {
  source = "../../modules/identity"

  key_vault_name                       = var.key_vault_name
  location                             = var.location
  resource_group_name                  = module.landing_zone.resource_group_names[var.identity_resource_group_name]
  key_vault_allowed_ips                = var.key_vault_allowed_ips
  key_vault_soft_delete_retention_days = var.key_vault_soft_delete_retention_days

  log_analytics_workspace_id = module.monitoring.workspace_id

  azl_key_vault_name           = var.azl_key_vault_name
  azl_key_vault_resource_group = var.azl_key_vault_resource_group_name == "" ? "" : module.landing_zone.resource_group_names[var.azl_key_vault_resource_group_name]

  # Purge protection of the platform vault follows scenario.environment_class (Deploy-KeyVaults.ps1); the cluster vault takes its retention
  # from cluster.key_vault.soft_delete_retention_days and has no purge protection, as Microsoft's deployment template makes it.
  environment_class                        = var.environment_class
  azl_key_vault_soft_delete_retention_days = var.azl_key_vault_soft_delete_retention_days

  deployment_spn_object_id    = var.deployment_spn_object_id
  azure_local_subscription_id = var.azure_local_subscription_id
  spn_subscription_roles      = var.spn_subscription_roles
  spn_resource_group_roles    = var.spn_resource_group_roles

  managed_identities = var.managed_identities

  tags = var.tags

  depends_on = [module.landing_zone, module.monitoring]
}

# -----------------------------------------------------------------------------
# Phase 5: Security — Azure Policy, Defender for Cloud
# -----------------------------------------------------------------------------
module "security" {
  source = "../../modules/security"

  subscription_id        = var.azure_local_subscription_id
  security_contact_email = var.security_contact_email
  alert_notifications    = var.alert_notifications
  alerts_to_admins       = var.alerts_to_admins
  policy_assignments     = var.policy_assignments
  rg_policy_assignments = {
    for name, a in var.rg_policy_assignments : name => {
      resource_group_id      = module.landing_zone.resource_group_ids[a.resource_group]
      policy_definition_id   = a.policy_definition_id
      display_name           = a.display_name
      description            = a.description
      enforce                = a.enforce
      non_compliance_message = a.non_compliance_message
    }
  }

  depends_on = [module.landing_zone]
}

# -----------------------------------------------------------------------------
# Phase 6: Compute — Management VMs, each in its own resource group
# -----------------------------------------------------------------------------
module "compute" {
  source = "../../modules/compute"

  management_vms = {
    for key, vm in var.management_vms : key => merge(vm, {
      subnet_id      = module.networking.subnet_ids[vm.subnet_key]
      resource_group = module.landing_zone.resource_group_names[vm.resource_group]
    })
  }
  location       = var.location
  admin_password = var.vm_admin_password
  key_vault_id   = module.identity.key_vault_id

  tags = var.tags

  depends_on = [module.networking, module.identity]
}
