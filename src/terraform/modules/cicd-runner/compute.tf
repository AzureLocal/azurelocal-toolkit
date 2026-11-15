# =============================================================================
# cicd-runner module - the machines
# =============================================================================
# Linux: VMs or a VM scale set; cloud-init runs templates/bootstrap-linux.sh.tftpl.
# Windows: VMs only; Azure Run Command runs templates/bootstrap-windows.ps1.tftpl.
# Both read the registration credential from Key Vault through the managed
# identity at boot. The credential is never a variable and never in state.
# =============================================================================

locals {
  # devops.runners[].image when the file sets it; otherwise the image of the OS in default_images (a setting of this code).
  image         = var.image != null ? var.image : var.default_images[var.os_type]
  linux_image   = local.image
  windows_image = local.image

  # devops.runners[].os_disk_size_gb when the file sets it; otherwise the size of the OS in default_os_disk_size_gb.
  os_disk_size = var.os_disk_size_gb != null ? var.os_disk_size_gb : var.default_os_disk_size_gb[var.os_type]

  bootstrap_vars = {
    platform                     = local.platform
    scm_url                      = var.scm_url
    labels_csv                   = join(",", local.labels)
    github_runner_group          = var.github_runner_group
    azure_devops_pool            = var.azure_devops_pool
    vault_name                   = var.registration_secret.key_vault_name
    vault_suffix                 = var.registration_secret.dns_suffix
    secret_name                  = var.registration_secret.secret_name
    token_kind                   = var.registration_secret.kind
    identity_client_id           = azurerm_user_assigned_identity.this.client_id
    purpose                      = var.purpose
    service_account              = var.windows_service_account
    windows_root                 = var.windows_root
    init_data_disk               = tostring(var.data_disk_size_gb > 0)
    terraform_version            = var.tool_versions.terraform
    bicep_version                = var.tool_versions.bicep
    bicep_sha256                 = var.tool_versions.bicep_linux_sha256
    bicep_windows_sha256         = var.tool_versions.bicep_windows_sha256
    github_runner_version        = var.tool_versions.github_runner
    github_runner_sha256         = var.tool_versions.github_runner_sha256
    github_runner_windows_sha256 = var.tool_versions.github_runner_windows_sha256
    gitlab_runner_version        = var.tool_versions.gitlab_runner
    gitlab_runner_sha256         = var.tool_versions.gitlab_runner_sha256
    gitlab_runner_windows_sha256 = var.tool_versions.gitlab_runner_windows_sha256
    azure_devops_agent_version   = var.tool_versions.azure_devops_agent
    az_powershell_version        = var.tool_versions.az_powershell
    install_ansible              = tostring(var.install_ansible)
    ansible_core_version         = var.tool_versions.ansible_core
    ansible_collections_csv      = join(",", var.ansible_collections)
  }

  linux_bootstrap   = replace(templatefile("${path.module}/templates/bootstrap-linux.sh.tftpl", local.bootstrap_vars), "\r", "")
  windows_bootstrap = templatefile("${path.module}/templates/bootstrap-windows.ps1.tftpl", local.bootstrap_vars)
  cloud_init        = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", { script_b64 = base64encode(local.linux_bootstrap) })

  linux_vms   = !local.is_windows && local.use_vm ? local.instances : {}
  windows_vms = local.is_windows && local.use_vm ? local.instances : {}
  all_vms     = local.use_vm ? local.instances : {}
}

# -----------------------------------------------------------------------------
# VM network interfaces and data disks
# -----------------------------------------------------------------------------
resource "azurerm_network_interface" "vm" {
  for_each = local.all_vms

  name                = "${var.nic_name_prefix}${each.key}"
  location            = var.location
  resource_group_name = local.resource_group_name
  tags                = local.tags

  ip_configuration {
    name                          = var.ip_configuration_name
    subnet_id                     = local.subnet_id
    private_ip_address_allocation = try(var.private_ip_addresses[each.value.index], null) != null ? "Static" : "Dynamic"
    private_ip_address            = try(var.private_ip_addresses[each.value.index], null)
  }
}

resource "azurerm_managed_disk" "data" {
  for_each = var.data_disk_size_gb > 0 ? local.all_vms : {}

  name                 = "${var.data_disk_name_prefix}${each.key}"
  location             = var.location
  resource_group_name  = local.resource_group_name
  storage_account_type = var.os_disk_type
  # A new, empty data disk (the bootstrap initialises it).
  create_option = "Empty"
  disk_size_gb  = var.data_disk_size_gb
  zone          = length(var.zones) > 0 ? var.zones[each.value.index % length(var.zones)] : null
  tags          = local.tags
}

# -----------------------------------------------------------------------------
# Linux VMs
# -----------------------------------------------------------------------------
resource "azurerm_linux_virtual_machine" "this" {
  for_each = local.linux_vms

  name                            = each.key
  computer_name                   = each.value.computer_name
  location                        = var.location
  resource_group_name             = local.resource_group_name
  size                            = var.vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = var.disable_password_authentication
  network_interface_ids           = [azurerm_network_interface.vm[each.key].id]
  custom_data                     = base64encode(local.cloud_init)
  encryption_at_host_enabled      = var.encryption_at_host_enabled
  zone                            = length(var.zones) > 0 ? var.zones[each.value.index % length(var.zones)] : null
  tags                            = local.tags

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.admin_ssh_public_key
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.this.id]
  }

  os_disk {
    caching              = var.os_disk_caching
    storage_account_type = var.os_disk_type
    disk_size_gb         = local.os_disk_size
  }

  source_image_reference {
    publisher = local.linux_image.publisher
    offer     = local.linux_image.offer
    sku       = local.linux_image.sku
    version   = local.linux_image.version
  }

  dynamic "boot_diagnostics" {
    for_each = var.boot_diagnostics_enabled ? [1] : []
    content {}
  }

  # The identity needs its roles (including Key Vault Secrets User) before the first boot reads the secret.
  depends_on = [azurerm_role_assignment.this, azurerm_subnet_network_security_group_association.this]
}

resource "azurerm_virtual_machine_data_disk_attachment" "linux" {
  for_each = { for k, v in local.linux_vms : k => v if var.data_disk_size_gb > 0 }

  managed_disk_id    = azurerm_managed_disk.data[each.key].id
  virtual_machine_id = azurerm_linux_virtual_machine.this[each.key].id
  # The only data disk of the VM.
  lun     = 0
  caching = var.data_disk_caching
}

# -----------------------------------------------------------------------------
# Windows VMs
# -----------------------------------------------------------------------------
resource "random_password" "windows_admin" {
  count = local.is_windows ? 1 : 0

  length           = var.windows_password_policy.length
  special          = true
  override_special = var.windows_password_policy.special_characters
  min_upper        = var.windows_password_policy.min_upper
  min_lower        = var.windows_password_policy.min_lower
  min_numeric      = var.windows_password_policy.min_numeric
  min_special      = var.windows_password_policy.min_special
}

resource "azurerm_key_vault_secret" "windows_admin_password" {
  count = local.is_windows && var.windows_admin_password_secret_name != "" ? 1 : 0

  name         = var.windows_admin_password_secret_name
  value        = random_password.windows_admin[0].result
  key_vault_id = var.registration_secret.key_vault_id
  content_type = var.secret_content_type
  tags         = local.tags
}

resource "azurerm_windows_virtual_machine" "this" {
  for_each = local.windows_vms

  name                       = each.key
  computer_name              = each.value.computer_name
  location                   = var.location
  resource_group_name        = local.resource_group_name
  size                       = var.vm_size
  admin_username             = var.admin_username
  admin_password             = random_password.windows_admin[0].result
  network_interface_ids      = [azurerm_network_interface.vm[each.key].id]
  encryption_at_host_enabled = var.encryption_at_host_enabled
  zone                       = length(var.zones) > 0 ? var.zones[each.value.index % length(var.zones)] : null
  tags                       = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.this.id]
  }

  os_disk {
    caching              = var.os_disk_caching
    storage_account_type = var.os_disk_type
    disk_size_gb         = local.os_disk_size
  }

  source_image_reference {
    publisher = local.windows_image.publisher
    offer     = local.windows_image.offer
    sku       = local.windows_image.sku
    version   = local.windows_image.version
  }

  dynamic "boot_diagnostics" {
    for_each = var.boot_diagnostics_enabled ? [1] : []
    content {}
  }

  depends_on = [azurerm_role_assignment.this, azurerm_subnet_network_security_group_association.this]
}

resource "azurerm_virtual_machine_data_disk_attachment" "windows" {
  for_each = { for k, v in local.windows_vms : k => v if var.data_disk_size_gb > 0 }

  managed_disk_id    = azurerm_managed_disk.data[each.key].id
  virtual_machine_id = azurerm_windows_virtual_machine.this[each.key].id
  # The only data disk of the VM.
  lun     = 0
  caching = var.data_disk_caching
}

# Installs the tooling and registers the runner. Runs as SYSTEM. It runs again
# when the script text changes, and skips what is already done.
resource "azurerm_virtual_machine_run_command" "windows_bootstrap" {
  for_each = local.windows_vms

  name               = var.bootstrap_run_command_name
  location           = var.location
  virtual_machine_id = azurerm_windows_virtual_machine.this[each.key].id
  tags               = local.tags

  source {
    script = local.windows_bootstrap
  }

  timeouts {
    create = "${ceil(var.bootstrap_timeout_seconds / 60)}m"
    update = "${ceil(var.bootstrap_timeout_seconds / 60)}m"
  }

  depends_on = [azurerm_virtual_machine_data_disk_attachment.windows]
}

# -----------------------------------------------------------------------------
# Linux VM scale set
# -----------------------------------------------------------------------------
resource "azurerm_linux_virtual_machine_scale_set" "this" {
  count = !local.is_windows && local.use_vmss ? 1 : 0

  name                            = var.name_prefix
  computer_name_prefix            = var.computer_name_prefix
  location                        = var.location
  resource_group_name             = local.resource_group_name
  sku                             = var.vm_size
  instances                       = var.runner_count
  admin_username                  = var.admin_username
  disable_password_authentication = var.disable_password_authentication
  upgrade_mode                    = var.vmss_upgrade_mode
  custom_data                     = base64encode(local.cloud_init)
  encryption_at_host_enabled      = var.encryption_at_host_enabled
  zones                           = length(var.zones) > 0 ? var.zones : null
  tags                            = local.tags

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.admin_ssh_public_key
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.this.id]
  }

  os_disk {
    caching              = var.os_disk_caching
    storage_account_type = var.os_disk_type
    disk_size_gb         = local.os_disk_size
  }

  source_image_reference {
    publisher = local.linux_image.publisher
    offer     = local.linux_image.offer
    sku       = local.linux_image.sku
    version   = local.linux_image.version
  }

  network_interface {
    name = var.vmss_nic_name
    # A scale set NIC and its IP configuration: the one and only, so the primary ones.
    primary = true

    ip_configuration {
      name      = var.ip_configuration_name
      primary   = true
      subnet_id = local.subnet_id
    }
  }

  dynamic "boot_diagnostics" {
    for_each = var.boot_diagnostics_enabled ? [1] : []
    content {}
  }

  depends_on = [azurerm_role_assignment.this, azurerm_subnet_network_security_group_association.this]
}
