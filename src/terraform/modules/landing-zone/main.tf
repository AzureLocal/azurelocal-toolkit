# =============================================================================
# Landing Zone Module — Management Groups & Resource Groups
# =============================================================================
# Mirrors: Implementation Part 2, Phase 1 (Stage 03)
# Creates the management groups of landing_zone.management_groups[] in the tree
# their parent keys describe, puts each subscription of landing_zone.subscriptions[]
# under the management group it names, and creates the resource groups.
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
# Management Group Hierarchy
# A group whose parent is not in the list (or is not set) sits under that parent
# as it exists already (not set: the tenant root group). A management group tree
# has at most six levels below the tenant root (Microsoft Learn: What are Azure
# management groups?, https://learn.microsoft.com/azure/governance/management-groups/overview),
# so the groups are created level by level, each level after the one above it.
# -----------------------------------------------------------------------------
locals {
  # The ID of a management group is fixed by its name (Microsoft.Management/managementGroups/<name>).
  mg_id_prefix = "/providers/Microsoft.Management/managementGroups/"

  groups      = { for g in var.management_groups : g.name => g }
  group_names = keys(local.groups)
  parent_of   = { for n, g in local.groups : n => (g.parent == null ? "" : g.parent) }

  # Depth of each group in the list: 0 when its parent is outside the list.
  level0 = [for n in local.group_names : n if !contains(local.group_names, local.parent_of[n])]
  level1 = [for n in local.group_names : n if contains(local.level0, local.parent_of[n])]
  level2 = [for n in local.group_names : n if contains(local.level1, local.parent_of[n])]
  level3 = [for n in local.group_names : n if contains(local.level2, local.parent_of[n])]
  level4 = [for n in local.group_names : n if contains(local.level3, local.parent_of[n])]
  level5 = [for n in local.group_names : n if contains(local.level4, local.parent_of[n])]
  placed = concat(local.level0, local.level1, local.level2, local.level3, local.level4, local.level5)

  parent_id = { for n in local.group_names : n => (local.parent_of[n] == "" ? null : "${local.mg_id_prefix}${local.parent_of[n]}") }
}

resource "terraform_data" "management_group_tree" {
  input = local.placed

  lifecycle {
    precondition {
      condition     = length(local.placed) == length(local.group_names)
      error_message = "landing_zone.management_groups[] is deeper than six levels, or a parent chain loops."
    }
  }
}

resource "azurerm_management_group" "level0" {
  for_each = toset(local.level0)

  name                       = each.value
  display_name               = coalesce(local.groups[each.value].display_name, each.value)
  parent_management_group_id = local.parent_id[each.value]

  depends_on = [terraform_data.management_group_tree]
}

resource "azurerm_management_group" "level1" {
  for_each = toset(local.level1)

  name                       = each.value
  display_name               = coalesce(local.groups[each.value].display_name, each.value)
  parent_management_group_id = local.parent_id[each.value]

  depends_on = [azurerm_management_group.level0]
}

resource "azurerm_management_group" "level2" {
  for_each = toset(local.level2)

  name                       = each.value
  display_name               = coalesce(local.groups[each.value].display_name, each.value)
  parent_management_group_id = local.parent_id[each.value]

  depends_on = [azurerm_management_group.level1]
}

resource "azurerm_management_group" "level3" {
  for_each = toset(local.level3)

  name                       = each.value
  display_name               = coalesce(local.groups[each.value].display_name, each.value)
  parent_management_group_id = local.parent_id[each.value]

  depends_on = [azurerm_management_group.level2]
}

resource "azurerm_management_group" "level4" {
  for_each = toset(local.level4)

  name                       = each.value
  display_name               = coalesce(local.groups[each.value].display_name, each.value)
  parent_management_group_id = local.parent_id[each.value]

  depends_on = [azurerm_management_group.level3]
}

resource "azurerm_management_group" "level5" {
  for_each = toset(local.level5)

  name                       = each.value
  display_name               = coalesce(local.groups[each.value].display_name, each.value)
  parent_management_group_id = local.parent_id[each.value]

  depends_on = [azurerm_management_group.level4]
}

locals {
  management_group_ids = merge(
    { for k, g in azurerm_management_group.level0 : k => g.id },
    { for k, g in azurerm_management_group.level1 : k => g.id },
    { for k, g in azurerm_management_group.level2 : k => g.id },
    { for k, g in azurerm_management_group.level3 : k => g.id },
    { for k, g in azurerm_management_group.level4 : k => g.id },
    { for k, g in azurerm_management_group.level5 : k => g.id },
  )
}

# -----------------------------------------------------------------------------
# Subscription to Management Group Associations: each subscription that has an
# id and names a management group goes under that group.
# -----------------------------------------------------------------------------
resource "azurerm_management_group_subscription_association" "subscriptions" {
  for_each = { for s in var.subscriptions : s.name => s if s.id != "" && s.management_group != "" }

  management_group_id = contains(local.group_names, each.value.management_group) ? local.management_group_ids[each.value.management_group] : "${local.mg_id_prefix}${each.value.management_group}"
  subscription_id     = "/subscriptions/${each.value.id}"
}

# -----------------------------------------------------------------------------
# Resource Groups — organized by function
# -----------------------------------------------------------------------------
resource "azurerm_resource_group" "groups" {
  for_each = var.resource_groups

  name     = each.value
  location = var.location
  tags     = var.tags
}
