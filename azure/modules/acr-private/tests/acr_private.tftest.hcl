# Offline unit tests with a mocked azurerm provider (no credentials needed).

mock_provider "azurerm" {}

variables {
  name                       = "acrhubspoketest"
  resource_group_name        = "rg-test"
  location                   = "germanywestcentral"
  private_endpoint_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-nodes"
  virtual_network_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test"
}

run "registry_is_private_premium_and_keyless" {
  command = plan

  assert {
    condition = (
      azurerm_container_registry.this.sku == "Premium" &&
      azurerm_container_registry.this.public_network_access_enabled == false &&
      azurerm_container_registry.this.admin_enabled == false &&
      azurerm_container_registry.this.anonymous_pull_enabled == false
    )
    error_message = "Premium, no public network, no admin user, no anonymous pull."
  }
}

run "aks_cache_rule_matches_microsofts_contract" {
  command = plan

  assert {
    condition = (
      azurerm_container_registry_cache_rule.aks_mcr[0].name == "aks-managed-mcr" &&
      azurerm_container_registry_cache_rule.aks_mcr[0].source_repo == "mcr.microsoft.com/*" &&
      azurerm_container_registry_cache_rule.aks_mcr[0].target_repo == "aks-managed-repository/*"
    )
    error_message = "A network-isolated AKS cluster bootstraps only from this exact cache rule."
  }
}

run "private_endpoint_and_dns" {
  command = plan

  assert {
    condition = (
      toset(azurerm_private_endpoint.acr.private_service_connection[0].subresource_names) == toset(["registry"]) &&
      azurerm_private_dns_zone.acr.name == "privatelink.azurecr.io" &&
      azurerm_private_dns_zone_virtual_network_link.acr.registration_enabled == false
    )
    error_message = "The registry must be reachable only through a private endpoint with privatelink DNS."
  }
}

run "cache_rule_is_optional" {
  command = plan

  variables {
    aks_bootstrap_cache_rule = false
  }

  assert {
    condition     = length(azurerm_container_registry_cache_rule.aks_mcr) == 0
    error_message = "No cache rule when the registry isn't an AKS bootstrap source."
  }
}

run "rejects_invalid_name" {
  command = plan

  variables {
    name = "acr-hubspoke"
  }

  expect_failures = [var.name]
}
