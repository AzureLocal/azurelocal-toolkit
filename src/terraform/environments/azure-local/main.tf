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

  management_groups = {
    parent_id              = null
    root_name              = var.management_groups.root_name
    root_display_name      = var.management_groups.root_display_name
    platform_name          = var.management_groups.platform_name
    platform_display_name  = var.management_groups.platform_display_name
    identity_name          = var.management_groups.identity_name
    connectivity_name      = var.management_groups.connectivity_name
    management_name        = var.management_groups.management_name
    security_name          = var.management_groups.security_name
    landing_zones_name     = var.management_groups.landing_zones_name
  }

  subscriptions = {
    connectivity_id = var.subscriptions.connectivity_id
    identity_id     = var.subscriptions.identity_id
    management_id   = var.subscriptions.management_id
    security_id     = var.subscriptions.security_id
    azure_local_id  = var.subscriptions.azure_local_id
    workloads_id    = var.subscriptions.workloads_id
  }

  resource_groups = var.resource_groups
  location        = var.location
  tags            = var.tags
}

# -----------------------------------------------------------------------------
# Phase 2: Networking — VNet, Subnets, NSGs, VPN, Bastion
# -----------------------------------------------------------------------------
module "networking" {
  source = "../../modules/networking"

  vnet_name          = var.vnet_name
  vnet_address_space = var.vnet_address_space
  location           = var.location
  resource_group_name = module.landing_zone.resource_group_names["connectivity_hub"]
  org_code           = var.org_code
  dns_servers        = var.dns_servers
  subnets            = var.subnets
  nsgs               = var.nsgs
  nsg_subnet_map     = var.nsg_subnet_map

  enable_nat_gateway       = var.enable_nat_gateway
  nat_gateway_idle_timeout = var.nat_gateway_idle_timeout

  enable_vpn_gateway = var.enable_vpn_gateway
  vpn_config         = var.vpn_config
  vpn_shared_key     = var.vpn_shared_key

  enable_bastion = var.enable_bastion
  bastion_config = var.bastion_config

  tags = var.tags

  depends_on = [module.landing_zone]
}

# -----------------------------------------------------------------------------
# Phase 3: Monitoring — Log Analytics (created before Identity for diagnostics)
# -----------------------------------------------------------------------------
module "monitoring" {
  source = "../../modules/monitoring"

  workspace_name      = var.log_analytics_workspace_name
  location            = var.location
  resource_group_name = module.landing_zone.resource_group_names["management_monitoring"]
  org_code            = var.org_code
  sku                 = var.log_analytics_sku
  retention_days      = var.log_analytics_retention_days
  alert_email_addresses = var.alert_email_addresses

  enable_cluster_alerts = false
  alert_scopes          = []

  tags = var.tags

  depends_on = [module.landing_zone]
}

# -----------------------------------------------------------------------------
# Phase 4: Identity — Key Vault, RBAC, Managed Identities
# -----------------------------------------------------------------------------
module "identity" {
  source = "../../modules/identity"

  key_vault_name        = var.key_vault_name
  location              = var.location
  resource_group_name   = module.landing_zone.resource_group_names["identity_mgmt"]
  key_vault_allowed_ips = var.key_vault_allowed_ips

  log_analytics_workspace_id = module.monitoring.workspace_id

  azl_key_vault_name           = var.azl_key_vault_name
  azl_key_vault_resource_group = module.landing_zone.resource_group_names["azurelocal_arc"]

  deployment_spn_object_id    = var.deployment_spn_object_id
  azure_local_subscription_id = var.subscriptions.azure_local_id
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

  subscription_id        = var.subscriptions.azure_local_id
  security_contact_email = var.security_contact_email
  defender_plans         = var.defender_plans
  policy_assignments     = var.policy_assignments
  rg_policy_assignments  = var.rg_policy_assignments

  depends_on = [module.landing_zone]
}

# -----------------------------------------------------------------------------
# Phase 6: Compute — Management VMs
# -----------------------------------------------------------------------------
module "compute" {
  source = "../../modules/compute"

  management_vms      = var.management_vms
  location            = var.location
  resource_group_name = module.landing_zone.resource_group_names["workload_compute"]
  admin_username      = var.vm_admin_username
  admin_password      = var.vm_admin_password
  windows_server_sku  = var.windows_server_sku
  key_vault_id        = module.identity.key_vault_id

  tags = var.tags

  depends_on = [module.networking, module.identity]
}
