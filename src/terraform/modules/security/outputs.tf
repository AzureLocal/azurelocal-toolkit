# =============================================================================
# Security Module — Outputs
# =============================================================================

output "policy_assignment_ids" {
  description = "Map of policy assignment name to ID."
  value       = { for k, pa in azurerm_subscription_policy_assignment.assignments : k => pa.id }
}

output "defender_plan_ids" {
  description = "Map of Defender plan to resource ID."
  value       = { for k, plan in azurerm_security_center_subscription_pricing.plans : k => plan.id }
}
