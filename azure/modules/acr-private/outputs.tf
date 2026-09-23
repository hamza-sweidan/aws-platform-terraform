output "id" {
  description = "Registry resource ID (bootstrap_profile.container_registry_id, AcrPull scope)."
  value       = azurerm_container_registry.this.id

  # Contract: a network-isolated cluster pulls its system images through the
  # private endpoint during node bootstrap. Anything built from this ID waits
  # for the endpoint, its DNS records and the cache rule.
  depends_on = [
    azurerm_private_endpoint.acr,
    azurerm_private_dns_zone_virtual_network_link.acr,
    azurerm_container_registry_cache_rule.aks_mcr,
  ]
}

output "name" {
  description = "Registry name."
  value       = azurerm_container_registry.this.name
}

output "login_server" {
  description = "Registry login server, e.g. <name>.azurecr.io."
  value       = azurerm_container_registry.this.login_server
}

output "private_endpoint_id" {
  description = "Private endpoint ID."
  value       = azurerm_private_endpoint.acr.id
}
