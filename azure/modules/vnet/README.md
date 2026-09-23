# vnet

One virtual network with private subnets, each behind its own NSG. The hub
and both spokes are built from this same module; what makes a VNet a hub or
a spoke is the peering (`vnet-peering`), not a different resource shape.

## Security baseline

Every subnet gets its own NSG. The module adds these rules to whatever the
caller passes in `subnets[*].nsg_rules` (caller priorities 100-3999):

| Priority | Rule | Why |
|---|---|---|
| 4000 | `AllowSameSubnetInBound` | Hosts in one subnet can reach each other. |
| 4096 | `DenyVnetInBound` | Overrides Azure's default **AllowVnetInBound** (65000). The `VirtualNetwork` service tag covers *every peered VNet*, so without this rule, peering a spoke opens every port on every hub subnet to it. East-west traffic now has to be allowed explicitly. |
| 4096 (outbound) | `DenyInternetOutBound` | Overrides the default **AllowInternetOutBound** (65001). Toggle with `deny_internet_outbound`. |

The default **AllowAzureLoadBalancerInBound** (65001) stays, so load balancer
health probes keep working.

Two more subnet settings back this up:

- `default_outbound_access_enabled = false`: the subnet is *private*. VMs get
  no implicit SNAT to the internet. Azure is retiring default outbound access,
  but the provider still defaults to `true`, so the module sets it explicitly.
- `private_endpoint_network_policies = "Enabled"`: NSG rules also apply to
  private endpoints in the subnet, so they can't bypass the baseline.

## Design notes

- **Rules are inline and authoritative.** A rule added by hand in the portal
  shows up as drift and is removed on the next apply. Separate
  `azurerm_network_security_rule` resources would ignore it.
- **One NSG per subnet**, not one per VNet. Each subnet's rule set can be
  read on its own, and a change to one tier can't open another.
- **`remote_address_prefixes`** is the other side of a rule: the source of an
  inbound rule, the destination of an outbound one. This subnet is always the
  other end, so a rule can't accidentally apply to a wider range.
- **`subnet_ids` waits for the NSG associations** (`depends_on` on the
  output), so nothing a caller builds in a subnet can land before its NSG.
- **Platform subnets aren't created here.** `GatewaySubnet`,
  `AzureFirewallSubnet` and `AzureBastionSubnet` need exact names and either
  no NSG or a prescribed one. Every subnet this module creates is named
  `snet-<key>`, so it can't produce them by mistake.

## Tests

`tests/vnet.tftest.hcl` runs with a mocked azurerm provider (no credentials).
It checks the baseline rules, the inbound/outbound field mapping, and that
bad input (reserved priorities, duplicate priorities, a service tag inside a
prefix list) is rejected at plan time.

```bash
terraform init -backend=false && terraform test
```

## Usage

```hcl
module "hub" {
  source = "../../modules/vnet"

  name                = "hubspoke-hub-dev"
  resource_group_name = azurerm_resource_group.hub.name
  location            = "germanywestcentral"
  address_space       = ["10.10.0.0/22"]

  subnets = {
    shared = {
      address_prefix = "10.10.1.0/24"
      nsg_rules = {
        AllowDnsFromSpokes = {
          priority                = 100
          direction               = "Inbound"
          protocol                = "*"
          remote_address_prefixes = ["10.11.0.0/22", "10.12.0.0/22"]
          destination_port_ranges = ["53"]
        }
      }
    }
  }

  tags = local.tags
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
| [azurerm_network_security_group.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/network_security_group) | resource |
| [azurerm_subnet.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet_network_security_group_association.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet_network_security_group_association) | resource |
| [azurerm_virtual_network.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/virtual_network) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| address\_space | VNet address space. Must not overlap any VNet it will be peered with. | `list(string)` | n/a | yes |
| location | Azure region. | `string` | n/a | yes |
| name | Base name, e.g. hubspoke-hub-dev. Resources become vnet-<name>, snet-<subnet> and nsg-<name>-<subnet>. | `string` | n/a | yes |
| resource\_group\_name | Resource group for the VNet and its NSGs. | `string` | n/a | yes |
| subnets | Subnets keyed by short name (snet-<key>). Every subnet gets its own NSG with<br/>the module's baseline rules (see README) plus the rules given here. For each<br/>rule, remote\_address\_prefixes is the source of an Inbound rule and the<br/>destination of an Outbound rule; the other side is always this subnet. | <pre>map(object({<br/>    address_prefix = string<br/>    nsg_rules = optional(map(object({<br/>      priority                = number<br/>      direction               = string<br/>      access                  = optional(string, "Allow")<br/>      protocol                = string<br/>      remote_address_prefixes = list(string)<br/>      destination_port_ranges = list(string)<br/>      description             = optional(string, "")<br/>    })), {})<br/>  }))</pre> | n/a | yes |
| deny\_internet\_outbound | Add a DenyInternetOutBound rule to every NSG, overriding Azure's default AllowInternetOutBound. | `bool` | `true` | no |
| tags | Tags for the VNet and NSGs. azurerm has no provider default\_tags, so the caller passes them explicitly. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| address\_space | VNet address space. |
| id | VNet resource ID. |
| name | VNet name. |
| network\_security\_group\_ids | NSG IDs by subnet key. |
| resource\_group\_name | Resource group of the VNet (peering resources are created there). |
| subnet\_address\_prefixes | Subnet CIDRs by subnet key. |
| subnet\_ids | Subnet IDs by subnet key. Only returned once every subnet has its NSG attached (see depends\_on). |
<!-- END_TF_DOCS -->
