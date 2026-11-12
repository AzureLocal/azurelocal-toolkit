# =============================================================================
# Security Module — Outputs
# =============================================================================

output "policy_assignment_ids" {
  description = "Map of policy assignment name to ID."
  value       = { for k, pa in azurerm_subscription_policy_assignment.assignments : k => pa.id }
}
