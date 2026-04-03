# =============================================================================
# Compute Module — Management VMs (DC, Jumpbox, WAC, Syslog)
# =============================================================================
# Mirrors: Implementation Part 2, Phase 4 (Stage 06) — Management VMs
# Provisions VM shells only. Guest OS config is handled by Ansible/PowerShell.
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

  name                = "nic-${each.value.vm_name}"
  location            = var.location
  resource_group_name = var.resource_group_name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = each.value.subnet_id
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
  resource_group_name   = var.resource_group_name
  size                  = each.value.vm_size
  admin_username        = var.admin_username
  admin_password        = var.admin_password
  network_interface_ids = [azurerm_network_interface.vm_nics[each.key].id]

  os_disk {
    name                 = "osdisk-${each.value.vm_name}"
    caching              = "ReadWrite"
    storage_account_type = each.value.os_disk_type
    disk_size_gb         = each.value.os_disk_size_gb
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = var.windows_server_sku
    version   = "latest"
  }

  identity {
    type = "SystemAssigned"
  }

  boot_diagnostics {}

  tags = merge(var.tags, {
    Role = each.value.role
  })
}

# -----------------------------------------------------------------------------
# Store admin credentials in Key Vault
# -----------------------------------------------------------------------------
resource "azurerm_key_vault_secret" "vm_admin_password" {
  count = var.key_vault_id != "" ? 1 : 0

  name         = "vm-admin-password"
  value        = var.admin_password
  key_vault_id = var.key_vault_id

  content_type = "password"
}
