# Offline unit tests with a mocked azurerm provider (no credentials needed).

mock_provider "azurerm" {}

variables {
  hub = {
    id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hubspoke-hub-dev"
    name                = "vnet-hubspoke-hub-dev"
    resource_group_name = "rg-hub"
    address_space       = ["10.10.0.0/22"]
  }
  spoke = {
    id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-spoke1/providers/Microsoft.Network/virtualNetworks/vnet-hubspoke-spoke1-dev"
    name                = "vnet-hubspoke-spoke1-dev"
    resource_group_name = "rg-spoke1"
    address_space       = ["10.11.0.0/22"]
  }
}

run "creates_both_links_with_safe_defaults" {
  command = plan

  assert {
    condition     = azurerm_virtual_network_peering.hub_to_spoke.name == "peer-hubspoke-hub-dev-to-hubspoke-spoke1-dev"
    error_message = "Hub link name should drop the vnet- prefixes."
  }

  assert {
    condition = (
      azurerm_virtual_network_peering.hub_to_spoke.resource_group_name == "rg-hub" &&
      azurerm_virtual_network_peering.spoke_to_hub.resource_group_name == "rg-spoke1"
    )
    error_message = "Each link must live in its own VNet's resource group."
  }

  assert {
    condition = (
      !azurerm_virtual_network_peering.hub_to_spoke.allow_forwarded_traffic &&
      !azurerm_virtual_network_peering.spoke_to_hub.allow_forwarded_traffic &&
      !azurerm_virtual_network_peering.hub_to_spoke.allow_gateway_transit &&
      !azurerm_virtual_network_peering.spoke_to_hub.use_remote_gateways
    )
    error_message = "Forwarding and gateway transit must be off by default."
  }

  assert {
    condition     = azurerm_virtual_network_peering.hub_to_spoke.triggers.remote_address_space == "10.11.0.0/22"
    error_message = "The hub link must re-sync when the spoke's address space changes."
  }
}

run "gateway_transit_sets_both_sides" {
  command = plan

  variables {
    use_hub_gateway = true
  }

  assert {
    condition = (
      azurerm_virtual_network_peering.hub_to_spoke.allow_gateway_transit &&
      azurerm_virtual_network_peering.spoke_to_hub.use_remote_gateways
    )
    error_message = "use_hub_gateway must set allow_gateway_transit on the hub and use_remote_gateways on the spoke."
  }
}
