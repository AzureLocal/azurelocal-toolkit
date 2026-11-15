# =============================================================================
# CI/CD infrastructure - self-hosted runners
# =============================================================================
# Task 06 of automation / 01-cicd-infra. Two runner pools, each one entry of
# devops.runners[] in infrastructure.yml:
#
#   runners_linux  the general runner (os_type linux): ARM, Arc, Terraform, Ansible,
#                  OS-configuration jobs. Creates the VNet, peers it with the hub.
#   runners_ztp    the ztp runner (purpose ztp, a Windows VM) for azurelocal-ztp (Boot,
#                  Bootstrap, Vouchers). Own subnet in the same VNet; inbound 445 from
#                  the BMC ranges.
#
# Plan first, review, then apply (terraform.tfvars.json is the file New-IacVariableFiles.ps1
# or task 06 writes from infrastructure.yml):
#   terraform init -backend-config=backend.hcl
#   terraform plan -var-file=terraform.tfvars.json -out=cicd.tfplan
#   terraform apply cicd.tfplan
# =============================================================================

locals {
  linux_secret_name = var.registration_secret.secret_name
  ztp_secret_name   = var.registration_secret.ztp_secret_name != "" ? var.registration_secret.ztp_secret_name : var.registration_secret.secret_name

  linux_existing_vnet = one(module.runners_linux[*].vnet_name)
}

module "runners_linux" {
  source = "../../modules/cicd-runner"
  count  = var.linux_runner.enabled ? 1 : 0

  providers = {
    azurerm     = azurerm
    azurerm.hub = azurerm.hub
  }

  name_prefix           = var.linux_runner.name_prefix
  computer_name_prefix  = var.linux_runner.computer_name_prefix
  location              = var.location
  resource_group_name   = var.resource_group_name
  create_resource_group = var.create_resource_group
  tags                  = var.tags

  os_type              = var.linux_runner.os_type
  purpose              = var.linux_runner.purpose
  platform             = var.platform
  scm_url              = var.scm_url
  github_runner_group  = var.github_runner_group
  azure_devops_pool    = var.azure_devops_pool
  extra_labels         = var.linux_runner.extra_labels
  admin_ssh_public_key = var.admin_ssh_public_key

  registration_secret = {
    key_vault_id   = var.registration_secret.key_vault_id
    key_vault_name = var.registration_secret.key_vault_name
    secret_name    = local.linux_secret_name
    kind           = var.registration_secret.kind
    dns_suffix     = var.registration_secret.dns_suffix
  }

  compute_type               = var.linux_runner.compute_type
  runner_count               = var.linux_runner.count
  vm_size                    = var.linux_runner.vm_size
  admin_username             = var.linux_runner.admin_username
  os_disk_size_gb            = var.linux_runner.os_disk_size_gb
  os_disk_type               = var.linux_runner.os_disk_type
  os_disk_caching            = var.linux_runner.os_disk_caching
  data_disk_caching          = var.linux_runner.data_disk_caching
  encryption_at_host_enabled = var.linux_runner.encryption_at_host
  zones                      = var.linux_runner.zones
  image                      = var.linux_runner.image
  private_ip_addresses       = var.linux_runner.private_ip_addresses
  install_ansible            = var.linux_runner.install_ansible
  nsg_name                   = var.linux_runner.nsg_name
  managed_identity_name      = var.linux_runner.identity_name

  vnet_name             = var.vnet_name
  vnet_address_space    = var.vnet_address_space
  subnet_name           = try(var.linux_subnet.name, "")
  subnet_address_prefix = try(var.linux_subnet.address_prefix, "")
  dns_servers           = var.dns_servers
  hub_peering           = var.hub_peering
  reachable_cidrs       = var.reachable_cidrs
  reachable_tcp_ports   = var.reachable_tcp_ports
  allow_internet_https  = var.allow_internet_https
  allow_internet_http   = var.allow_internet_http
  allow_icmp            = var.allow_icmp
  admin_source_cidrs    = var.admin_source_cidrs

  contributor_scopes                    = var.contributor_scopes
  rbac_administrator_scopes             = var.rbac_administrator_scopes
  rbac_administrator_delegable_role_ids = var.rbac_administrator_delegable_role_ids
  arc_machine_scopes                    = var.arc_machine_scopes
  key_vault_reader_ids                  = var.key_vault_reader_ids
  additional_role_assignments           = var.additional_role_assignments

  tool_versions = var.tool_versions
}

module "runners_ztp" {
  source = "../../modules/cicd-runner"
  count  = var.ztp_runner.enabled ? 1 : 0

  providers = {
    azurerm     = azurerm
    azurerm.hub = azurerm.hub
  }

  name_prefix           = var.ztp_runner.name_prefix
  computer_name_prefix  = var.ztp_runner.computer_name_prefix
  location              = var.location
  resource_group_name   = var.resource_group_name
  create_resource_group = var.create_resource_group && !var.linux_runner.enabled
  tags                  = var.tags

  # The module's preconditions hold the design limit: a ztp runner is a Windows VM.
  os_type             = var.ztp_runner.os_type
  purpose             = var.ztp_runner.purpose
  platform            = var.platform
  scm_url             = var.scm_url
  github_runner_group = var.github_ztp_runner_group
  azure_devops_pool   = var.azure_devops_ztp_pool
  extra_labels        = var.ztp_runner.extra_labels

  registration_secret = {
    key_vault_id   = var.registration_secret.key_vault_id
    key_vault_name = var.registration_secret.key_vault_name
    secret_name    = local.ztp_secret_name
    kind           = var.registration_secret.kind
    dns_suffix     = var.registration_secret.dns_suffix
  }

  compute_type               = var.ztp_runner.compute_type
  runner_count               = var.ztp_runner.count
  vm_size                    = var.ztp_runner.vm_size
  admin_username             = var.ztp_runner.admin_username
  os_disk_size_gb            = var.ztp_runner.os_disk_size_gb
  os_disk_type               = var.ztp_runner.os_disk_type
  os_disk_caching            = var.ztp_runner.os_disk_caching
  data_disk_caching          = var.ztp_runner.data_disk_caching
  encryption_at_host_enabled = var.ztp_runner.encryption_at_host
  zones                      = var.ztp_runner.zones
  image                      = var.ztp_runner.image
  data_disk_size_gb          = var.ztp_runner.data_disk_size_gb
  private_ip_addresses       = var.ztp_runner.private_ip_addresses
  nsg_name                   = var.ztp_runner.nsg_name
  managed_identity_name      = var.ztp_runner.identity_name

  windows_admin_password_secret_name = var.windows_admin_password_secret_name

  # Same VNet as the Linux runners when they exist; otherwise this pool creates it.
  existing_vnet = local.linux_existing_vnet == null ? null : {
    name                = local.linux_existing_vnet
    resource_group_name = var.resource_group_name
  }
  vnet_name             = var.vnet_name
  vnet_address_space    = var.vnet_address_space
  subnet_name           = try(var.ztp_subnet.name, "")
  subnet_address_prefix = try(var.ztp_subnet.address_prefix, "")
  dns_servers           = var.dns_servers
  hub_peering           = var.hub_peering
  reachable_cidrs       = var.reachable_cidrs
  reachable_tcp_ports   = var.reachable_tcp_ports
  allow_internet_https  = var.allow_internet_https
  allow_internet_http   = var.allow_internet_http
  allow_icmp            = var.allow_icmp
  bmc_cidrs             = var.bmc_cidrs
  admin_source_cidrs    = var.admin_source_cidrs

  contributor_scopes                    = var.contributor_scopes
  rbac_administrator_scopes             = var.rbac_administrator_scopes
  rbac_administrator_delegable_role_ids = var.rbac_administrator_delegable_role_ids
  arc_machine_scopes                    = var.arc_machine_scopes
  key_vault_reader_ids                  = var.key_vault_reader_ids
  additional_role_assignments           = var.additional_role_assignments

  tool_versions = var.tool_versions
}
