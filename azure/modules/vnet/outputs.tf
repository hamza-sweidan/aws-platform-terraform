output "id" {
  description = "VNet resource ID."
  value       = azurerm_virtual_network.this.id
}

output "name" {
  description = "VNet name."
  value       = azurerm_virtual_network.this.name
}

output "resource_group_name" {
  description = "Resource group of the VNet (peering resources are created there)."
  value       = azurerm_virtual_network.this.resource_group_name
}

output "address_space" {
  description = "VNet address space."
  value       = azurerm_virtual_network.this.address_space
}

output "subnet_ids" {
  description = "Subnet IDs by subnet key. Only returned once every subnet has its NSG attached (see depends_on)."
  value       = { for k, s in azurerm_subnet.this : k => s.id }

  # Contract: a subnet isn't usable until its NSG is attached. Anything a
  # caller builds from these IDs (NICs, private endpoints) waits for the
  # association, so nothing ever runs in a subnet without the baseline rules.
  depends_on = [azurerm_subnet_network_security_group_association.this]
}

output "subnet_address_prefixes" {
  description = "Subnet CIDRs by subnet key."
  value       = { for k, s in var.subnets : k => s.address_prefix }
}

output "network_security_group_ids" {
  description = "NSG IDs by subnet key."
  value       = { for k, n in azurerm_network_security_group.this : k => n.id }
}
