output "hub_to_spoke_id" {
  description = "ID of the hub-side peering link."
  value       = azurerm_virtual_network_peering.hub_to_spoke.id
}

output "spoke_to_hub_id" {
  description = "ID of the spoke-side peering link."
  value       = azurerm_virtual_network_peering.spoke_to_hub.id
}

output "names" {
  description = "Both link names, for az network vnet peering show."
  value = {
    hub_to_spoke = azurerm_virtual_network_peering.hub_to_spoke.name
    spoke_to_hub = azurerm_virtual_network_peering.spoke_to_hub.name
  }
}
