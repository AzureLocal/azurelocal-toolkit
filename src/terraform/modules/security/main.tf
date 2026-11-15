# =============================================================================
# Security Module — Azure Policy, Defender for Cloud
# =============================================================================
# Mirrors: Implementation Part 5, Phase 4 (Stage 20) — Security & Governance
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
# Microsoft Defender for Cloud — security contact only. This module sets no pricing tier:
# the toolkit turns on no paid plan. The free level Azure Local needs is set by
# Enable-DefenderForCloud.ps1.
# -----------------------------------------------------------------------------

resource "azurerm_security_center_contact" "main" {
  count = var.security_contact_email != "" ? 1 : 0

  # A subscription has one security contact and its name is always default (Microsoft Learn: Microsoft.Security securityContacts,
  # https://learn.microsoft.com/azure/templates/microsoft.security/securitycontacts).
  name  = "default"
  email = var.security_contact_email
  # security.defender_for_cloud.alert_notifications and alerts_to_admins.
  alert_notifications = var.alert_notifications
  alerts_to_admins    = var.alerts_to_admins
}

# -----------------------------------------------------------------------------
# Azure Policy — Assignments for Azure Local compliance (landing_zone.policy.assignments[])
# -----------------------------------------------------------------------------
resource "azurerm_subscription_policy_assignment" "assignments" {
  for_each = var.policy_assignments

  name                 = each.key
  subscription_id      = "/subscriptions/${var.subscription_id}"
  policy_definition_id = each.value.policy_definition_id
  display_name         = each.value.display_name
  description          = each.value.description
  enforce              = each.value.enforce

  dynamic "non_compliance_message" {
    for_each = each.value.non_compliance_message != "" ? [1] : []
    content {
      content = each.value.non_compliance_message
    }
  }
}

# -----------------------------------------------------------------------------
# Azure Policy — Resource group level assignments (landing_zone.policy.resource_group_assignments[])
# -----------------------------------------------------------------------------
resource "azurerm_resource_group_policy_assignment" "rg_assignments" {
  for_each = var.rg_policy_assignments

  name                 = each.key
  resource_group_id    = each.value.resource_group_id
  policy_definition_id = each.value.policy_definition_id
  display_name         = each.value.display_name
  description          = each.value.description
  enforce              = each.value.enforce

  dynamic "non_compliance_message" {
    for_each = each.value.non_compliance_message != "" ? [1] : []
    content {
      content = each.value.non_compliance_message
    }
  }
}
