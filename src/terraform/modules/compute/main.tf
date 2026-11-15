# =============================================================================
# Compute Module — Management VMs (DC, Jumpbox, WAC, Syslog)
# =============================================================================
# Mirrors: Implementation Part 2, Phase 4 (Stage 06) — Management VMs
# Provisions VM shells only. Guest OS config is handled by Ansible/PowerShell.
# Each VM takes its own keys of landing_zone.virtual_machines[]: resource group,
# size, address, administrator, image and disk.
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
# NICs for Management VMs
# -----------------------------------------------------------------------------
resource "azurerm_network_interface" "vm_nics" {
  for_each = var.management_vms

  name                = "${var.nic_name_prefix}${each.value.vm_name}"
  location            = var.location
  resource_group_name = each.value.resource_group

  ip_configuration {
    name      = var.ip_configuration_name
    subnet_id = each.value.subnet_id
    # landing_zone.virtual_machines[].private_ip is required: the address is set, never assigned by Azure.
    private_ip_address_allocation = "Static"
    private_ip_address            = each.value.private_ip
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Management Virtual Machines
# -----------------------------------------------------------------------------
resource "azurerm_windows_virtual_machine" "vms" {
  for_each = { for k, v in var.management_vms : k => v if v.deployment_target == "azure" }

  name                  = each.value.vm_name
  location              = var.location
  resource_group_name   = each.value.resource_group
  size                  = each.value.vm_size
  admin_username        = each.value.admin_username
  admin_password        = var.admin_password
  network_interface_ids = [azurerm_network_interface.vm_nics[each.key].id]

  os_disk {
    name                 = "${var.os_disk_name_prefix}${each.value.vm_name}"
    caching              = each.value.os_disk_caching
    storage_account_type = each.value.os_disk_type
    disk_size_gb         = each.value.os_disk_size_gb
  }

  # The Windows Server images: publisher MicrosoftWindowsServer, offer WindowsServer; the SKU follows landing_zone.virtual_machines[].os
  # (Microsoft Learn: Find and use Azure Marketplace VM images with Azure PowerShell).
  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = each.value.windows_server_sku
    version   = each.value.image_version
  }

  identity {
    type = var.identity_type
  }

  dynamic "boot_diagnostics" {
    for_each = var.boot_diagnostics_enabled ? [1] : []
    content {}
  }

  tags = merge(var.tags, {
    (var.role_tag_name) = each.value.role
  })
}

# -----------------------------------------------------------------------------
# Store admin credentials in Key Vault: the secret each VM names in
# landing_zone.virtual_machines[].admin_password (keyvault://<vault>/<secret>).
# -----------------------------------------------------------------------------
resource "azurerm_key_vault_secret" "vm_admin_password" {
  # Keyed by the secret names of the file, which are known at plan time (the vault ID is not before the vault exists).
  for_each = toset([for v in var.management_vms : v.admin_password_secret_name if v.admin_password_secret_name != ""])

  name         = each.value
  value        = var.admin_password
  key_vault_id = var.key_vault_id

  content_type = var.secret_content_type
}
