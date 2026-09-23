output "policy_definition_id" {
  description = "ID of the custom required-tags policy definition."
  value       = azurerm_policy_definition.require_tags.id
}

output "assignment_ids" {
  description = "Policy assignment IDs by resource group key."
  value       = { for k, a in azurerm_resource_group_policy_assignment.require_tags : k => a.id }
}

output "required_tags" {
  description = "The tag names being enforced."
  value       = var.required_tags
}
