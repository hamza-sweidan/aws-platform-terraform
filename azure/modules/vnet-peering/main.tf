# Hub <-> spoke peering. A peering is a pair of links, one owned by each
# VNet, and traffic only flows once both exist (peeringState = Connected).
# Keeping both in one module means a spoke can never be half-peered.
#
# Peering is not transitive: spoke1 <-> hub <-> spoke2 does NOT let spoke1
# reach spoke2. That isolation is the point of hub-and-spoke. Controlled
# spoke-to-spoke traffic would need a firewall in the hub, route tables in
# the spokes, and allow_forwarded_traffic = true.

locals {
  hub_short   = trimprefix(var.hub.name, "vnet-")
  spoke_short = trimprefix(var.spoke.name, "vnet-")
}

resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  name                      = "peer-${local.hub_short}-to-${local.spoke_short}"
  resource_group_name       = var.hub.resource_group_name
  virtual_network_name      = var.hub.name
  remote_virtual_network_id = var.spoke.id

  allow_virtual_network_access = true
  # Traffic from a spoke into the hub always originates in that spoke, so
  # the hub never needs to accept forwarded traffic.
  allow_forwarded_traffic = false
  allow_gateway_transit   = var.use_hub_gateway

  # Adding a range to a peered VNet leaves the link "not in sync" until it's
  # synced. A changed trigger makes Terraform run that sync.
  triggers = {
    remote_address_space = join(",", var.spoke.address_space)
  }
}

resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  name                      = "peer-${local.spoke_short}-to-${local.hub_short}"
  resource_group_name       = var.spoke.resource_group_name
  virtual_network_name      = var.spoke.name
  remote_virtual_network_id = var.hub.id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = var.allow_forwarded_traffic
  use_remote_gateways          = var.use_hub_gateway

  triggers = {
    remote_address_space = join(",", var.hub.address_space)
  }

  # use_remote_gateways fails if the hub side doesn't allow gateway transit yet.
  depends_on = [azurerm_virtual_network_peering.hub_to_spoke]
}
