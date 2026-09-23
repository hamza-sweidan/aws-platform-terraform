# vnet-peering

Peers one spoke VNet to the hub, **both directions** in one module. A peering
is two links, one owned by each VNet, and traffic only flows once both exist
(`peeringState = Connected`). Creating them together means a spoke can never
be left half-peered.

## Link settings

| Setting | Hub → spoke | Spoke → hub | Why |
|---|---|---|---|
| `allow_virtual_network_access` | `true` | `true` | Plain VNet-to-VNet traffic. What's actually allowed is then up to the NSGs (the vnet module denies `VirtualNetwork` inbound by default). |
| `allow_forwarded_traffic` | `false` | `var.allow_forwarded_traffic` (`false`) | Only the spoke ever receives *forwarded* traffic: packets a hub firewall/NVA relays from somewhere else, such as another spoke. Turn on once that firewall exists. |
| `allow_gateway_transit` / `use_remote_gateways` | `var.use_hub_gateway` | `var.use_hub_gateway` | Lets spokes reach on-premises through a VPN/ExpressRoute gateway in the hub. Off: there is no gateway, which would be billed by the hour. |
| `triggers.remote_address_space` | spoke ranges | hub ranges | Adding a range to a peered VNet leaves the link *not in sync* until it's synced. A changed trigger makes Terraform run that sync. |

## Peering is not transitive

`spoke1 <-> hub <-> spoke2` does **not** give spoke1 a route to spoke2. Each
VNet only learns the address space of the VNets it's directly peered with.
That isolation is the point of hub-and-spoke. To allow *controlled*
spoke-to-spoke traffic you would:

1. Deploy Azure Firewall (or an NVA) in the hub's reserved `AzureFirewallSubnet`.
2. Add route tables to the spoke subnets: other spokes' ranges → next hop the firewall's private IP.
3. Set `allow_forwarded_traffic = true` so spokes accept traffic the firewall relays.

See [ADR 0005](../../../docs/decisions/0005-hub-and-spoke-with-vnet-peering.md).

## Usage

```hcl
module "peering" {
  source   = "../../modules/vnet-peering"
  for_each = module.spoke

  hub = {
    id                  = module.hub.id
    name                = module.hub.name
    resource_group_name = module.hub.resource_group_name
    address_space       = module.hub.address_space
  }
  spoke = {
    id                  = each.value.id
    name                = each.value.name
    resource_group_name = each.value.resource_group_name
    address_space       = each.value.address_space
  }
}
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.9, < 2.0 |
| azurerm | >= 5.0, < 6.0 |

## Providers

| Name | Version |
| ---- | ------- |
| azurerm | >= 5.0, < 6.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [azurerm_virtual_network_peering.hub_to_spoke](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/virtual_network_peering) | resource |
| [azurerm_virtual_network_peering.spoke_to_hub](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/virtual_network_peering) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| hub | Hub VNet: the vnet module's id, name, resource\_group\_name and address\_space outputs. | <pre>object({<br/>    id                  = string<br/>    name                = string<br/>    resource_group_name = string<br/>    address_space       = list(string)<br/>  })</pre> | n/a | yes |
| spoke | Spoke VNet: the vnet module's id, name, resource\_group\_name and address\_space outputs. | <pre>object({<br/>    id                  = string<br/>    name                = string<br/>    resource_group_name = string<br/>    address_space       = list(string)<br/>  })</pre> | n/a | yes |
| allow\_forwarded\_traffic | Let the spoke accept traffic that a firewall or NVA in the hub forwards from elsewhere (e.g. from another spoke). Needed once spoke-to-spoke traffic is routed through a hub firewall. | `bool` | `false` | no |
| use\_hub\_gateway | Route the spoke's on-premises traffic through a VPN/ExpressRoute gateway in the hub (hub: allow\_gateway\_transit, spoke: use\_remote\_gateways). The hub must already have a gateway. | `bool` | `false` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| hub\_to\_spoke\_id | ID of the hub-side peering link. |
| names | Both link names, for az network vnet peering show. |
| spoke\_to\_hub\_id | ID of the spoke-side peering link. |
<!-- END_TF_DOCS -->
