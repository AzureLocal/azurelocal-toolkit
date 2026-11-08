# =============================================================================
# CI/CD infrastructure - outputs
# =============================================================================

output "linux_runners" {
  description = "The general Linux runners: names, host names (the name each registers under), IPs, identity."
  value = var.linux_runner.enabled ? {
    names                 = module.runners_linux[0].runner_names
    computer_names        = module.runners_linux[0].computer_names
    private_ip_addresses  = module.runners_linux[0].private_ip_addresses
    identity_id           = module.runners_linux[0].identity_id
    identity_principal_id = module.runners_linux[0].identity_principal_id
    identity_client_id    = module.runners_linux[0].identity_client_id
    labels                = module.runners_linux[0].labels
    role_assignments      = module.runners_linux[0].role_assignments
  } : null
}

output "ztp_runner" {
  description = "The ZTP Windows runner: names, host names, IP, identity. Pass identity_client_id to Connect-AzAccount when a job needs the identity explicitly."
  value = var.ztp_runner.enabled ? {
    names                 = module.runners_ztp[0].runner_names
    computer_names        = module.runners_ztp[0].computer_names
    private_ip_addresses  = module.runners_ztp[0].private_ip_addresses
    identity_id           = module.runners_ztp[0].identity_id
    identity_principal_id = module.runners_ztp[0].identity_principal_id
    identity_client_id    = module.runners_ztp[0].identity_client_id
    labels                = module.runners_ztp[0].labels
    role_assignments      = module.runners_ztp[0].role_assignments
  } : null
}

output "network" {
  description = "Network facts the network team needs: the VNet and the subnets whose ranges the lab firewall and the VPN local network gateway must route."
  value = {
    vnet_name           = var.vnet_name
    vnet_address_space  = var.vnet_address_space
    linux_subnet_prefix = try(var.linux_subnet.address_prefix, null)
    ztp_subnet_prefix   = try(var.ztp_subnet.address_prefix, null)
    bmc_cidrs           = var.bmc_cidrs
  }
}
