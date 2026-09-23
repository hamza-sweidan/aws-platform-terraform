output "resource_group_name" {
  description = "Resource group that holds the state account."
  value       = azurerm_resource_group.state.name
}

output "storage_account_name" {
  description = "Name of the storage account that stores Terraform state."
  value       = azurerm_storage_account.state.name
}

output "storage_account_id" {
  description = "Resource ID of the state account, for role assignments that grant state access."
  value       = azurerm_storage_account.state.id
}

output "container_name" {
  description = "Blob container that holds the state files."
  value       = azurerm_storage_container.state.name
}

output "backend_config" {
  description = "Partial backend config for azure/envs/*. Write it with: terraform output -raw backend_config > ../envs/dev/backend.hcl"
  value       = <<-EOT
    storage_account_name = "${azurerm_storage_account.state.name}"
    container_name       = "${azurerm_storage_container.state.name}"
  EOT
}

output "budget_name" {
  description = "Name of the monthly budget, or null if no alert email was given."
  value       = one(azurerm_consumption_budget_subscription.monthly[*].name)
}
