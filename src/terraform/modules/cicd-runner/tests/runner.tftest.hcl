# Offline tests for the cicd-runner module: mocked providers, plan only.
# Run: terraform init -backend=false && terraform test   (from this module's folder)

mock_provider "azurerm" {}

mock_provider "azurerm" {
  alias = "hub"
}

mock_provider "random" {}

variables {
  name_prefix           = "test-runner"
  location              = "eastus"
  resource_group_name   = "rg-test-runners"
  platform              = "github"
  scm_url               = "https://github.com/example-org"
  os_type               = "linux"
  admin_ssh_public_key  = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDB7vh8Ob2SpmbHdf4DndRVIIH5xYrGhLjfYd4m13+DyKjZ35gN5bSgJ6DptlvnhHNsyczLZoakfIBeQtgGMwf55mMBu2OMQ7jdtnh3IVNTzqZ8m8Aq5RQ6O3NHHlqyNzWOXK1nABi+lrE11nZLSPs0pPaEJQW5Ued/RY2MPNp5hu9gZUdMFTNU2J5QeAWw11F705uq21G42a6si8kAA0xgydrkJnzAmGNHESEZV8mCW/mH5KkYMEskRSl7YzsxJnP+CH7lmqUF/IN1HwINKQgxhjWbwa5quWZlIurMtT5IZ6fPj6Sr1fRUGaxGkhw50fvEDNtA+adI1M4wjI/qyXoP test@example.com"
  vnet_name             = "vnet-test"
  vnet_address_space    = ["10.250.10.0/24"]
  subnet_name           = "snet-test"
  subnet_address_prefix = "10.250.10.0/26"
  registration_secret = {
    key_vault_id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-kv/providers/Microsoft.KeyVault/vaults/kv-test"
    key_vault_name = "kv-test"
    secret_name    = "runner-token"
  }
}

run "linux_github_vm" {
  command = plan

  assert {
    condition     = length(azurerm_linux_virtual_machine.this) == 1 && length(azurerm_windows_virtual_machine.this) == 0
    error_message = "One Linux VM and no Windows VM are expected."
  }
  assert {
    condition     = contains(output.labels, "terraform") && contains(output.labels, "ansible") && !contains(output.labels, "ztp")
    error_message = "Linux general runners carry the terraform and ansible labels, not ztp."
  }
  assert {
    condition     = !contains(keys(azurerm_network_security_rule.this), "Allow-Inbound-BMC-SMB")
    error_message = "The general runner must not accept inbound SMB."
  }
  assert {
    condition     = contains(keys(azurerm_network_security_rule.this), "Deny-Inbound-Internet")
    error_message = "Inbound from the internet must be denied explicitly."
  }
  assert {
    condition     = length(azurerm_role_assignment.this) == 1 && contains(keys(azurerm_role_assignment.this), "key-vault-0")
    error_message = "With no scopes given, the identity gets only Key Vault Secrets User on the registration vault."
  }
}

run "windows_ztp" {
  command = plan

  variables {
    os_type           = "windows"
    purpose           = "ztp"
    bmc_cidrs         = ["192.168.20.0/24"]
    reachable_cidrs   = ["192.168.10.0/24"]
    data_disk_size_gb = 512
    vm_size           = "Standard_D4s_v5"
  }

  assert {
    condition     = length(azurerm_windows_virtual_machine.this) == 1 && length(azurerm_linux_virtual_machine.this) == 0
    error_message = "One Windows VM is expected."
  }
  assert {
    condition     = contains(output.labels, "ztp") && contains(output.labels, "windows")
    error_message = "The ztp runner carries the ztp and windows labels."
  }
  assert {
    condition     = azurerm_network_security_rule.this["Allow-Inbound-BMC-SMB"].destination_port_range == "445" && contains(azurerm_network_security_rule.this["Allow-Inbound-BMC-SMB"].source_address_prefix == null ? azurerm_network_security_rule.this["Allow-Inbound-BMC-SMB"].source_address_prefixes : [azurerm_network_security_rule.this["Allow-Inbound-BMC-SMB"].source_address_prefix], "192.168.20.0/24")
    error_message = "Inbound 445 must be allowed from the BMC range."
  }
  assert {
    condition     = length(azurerm_virtual_machine_run_command.windows_bootstrap) == 1 && length(azurerm_managed_disk.data) == 1
    error_message = "The Run Command bootstrap and the data disk are expected."
  }
}

run "ztp_needs_bmc_cidrs" {
  command = plan

  variables {
    os_type = "windows"
    purpose = "ztp"
  }

  expect_failures = [azurerm_user_assigned_identity.this]
}

run "ztp_needs_windows" {
  command = plan

  variables {
    purpose   = "ztp"
    bmc_cidrs = ["192.168.20.0/24"]
  }

  expect_failures = [azurerm_user_assigned_identity.this]
}

run "windows_refuses_vmss" {
  command = plan

  variables {
    os_type      = "windows"
    compute_type = "vmss"
  }

  expect_failures = [azurerm_user_assigned_identity.this]
}

run "linux_needs_ssh_key" {
  command = plan

  variables {
    admin_ssh_public_key = ""
  }

  expect_failures = [azurerm_user_assigned_identity.this]
}

run "linux_vmss" {
  command = plan

  variables {
    compute_type = "vmss"
    runner_count = 3
  }

  assert {
    condition     = length(azurerm_linux_virtual_machine_scale_set.this) == 1 && length(azurerm_linux_virtual_machine.this) == 0
    error_message = "A scale set and no VMs are expected."
  }
  assert {
    condition     = azurerm_linux_virtual_machine_scale_set.this[0].instances == 3
    error_message = "Three instances are expected."
  }
}

run "rbac_administrator_is_constrained" {
  command = plan

  variables {
    rbac_administrator_scopes             = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-cluster"]
    rbac_administrator_delegable_role_ids = ["4633458b-17de-408a-b874-0445c86b69e6"]
    contributor_scopes                    = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-cluster"]
  }

  assert {
    condition     = strcontains(azurerm_role_assignment.this["rbac-admin-0"].condition, "GuidEquals {4633458b-17de-408a-b874-0445c86b69e6}") && azurerm_role_assignment.this["rbac-admin-0"].condition_version == "2.0"
    error_message = "The RBAC Administrator assignment must carry the ABAC condition."
  }
  assert {
    condition     = azurerm_role_assignment.this["contributor-0"].condition == null
    error_message = "Contributor takes no condition."
  }
}

run "hub_peering_both_halves" {
  command = plan

  variables {
    hub_peering = {
      enabled     = true
      hub_vnet_id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub"
    }
  }

  assert {
    condition     = length(azurerm_virtual_network_peering.spoke_to_hub) == 1 && length(azurerm_virtual_network_peering.hub_to_spoke) == 1
    error_message = "Both halves of the peering are expected."
  }
  assert {
    condition     = azurerm_virtual_network_peering.hub_to_spoke[0].resource_group_name == "rg-hub" && azurerm_virtual_network_peering.hub_to_spoke[0].virtual_network_name == "vnet-hub" && azurerm_virtual_network_peering.hub_to_spoke[0].allow_gateway_transit
    error_message = "The hub half is created in the hub VNet with gateway transit."
  }
}

run "hub_peering_network_team_owns_hub_side" {
  command = plan

  variables {
    hub_peering = {
      enabled         = true
      hub_vnet_id     = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub"
      create_hub_side = false
    }
  }

  assert {
    condition     = length(azurerm_virtual_network_peering.spoke_to_hub) == 1 && length(azurerm_virtual_network_peering.hub_to_spoke) == 0
    error_message = "Only the spoke half is expected."
  }
}

run "hub_peering_needs_a_vnet_id" {
  command = plan

  variables {
    hub_peering = {
      enabled     = true
      hub_vnet_id = "not-an-id"
    }
  }

  expect_failures = [var.hub_peering]
}

run "existing_subnet_creates_no_network" {
  command = plan

  variables {
    existing_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-x/subnets/snet-x"
    vnet_name          = ""
    vnet_address_space = []
    subnet_name        = ""
  }

  assert {
    condition     = length(azurerm_virtual_network.this) == 0 && length(azurerm_subnet.this) == 0
    error_message = "No VNet and no subnet are created when a subnet is given."
  }
}

run "azdo_alias" {
  command = plan

  variables {
    platform          = "azdo"
    scm_url           = "https://dev.azure.com/example-org"
    azure_devops_pool = "pool-test"
  }

  assert {
    condition     = output.platform == "azure_devops"
    error_message = "azdo is an alias of azure_devops."
  }
}

run "azdo_needs_a_pool" {
  command = plan

  variables {
    platform = "azure_devops"
    scm_url  = "https://dev.azure.com/example-org"
  }

  expect_failures = [azurerm_user_assigned_identity.this]
}
