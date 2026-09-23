# One VNet with private subnets, each behind its own NSG. The same module
# builds the hub and every spoke: "hub" and "spoke" are roles set by the
# peering, not different shapes of network.
#
# NSG baseline, added to every subnet on top of the caller's rules:
# - 4000 AllowSameSubnetInBound: hosts in one subnet can talk to each other.
# - 4096 DenyVnetInBound: overrides Azure's default AllowVnetInBound (65000).
#   The VirtualNetwork service tag includes every peered VNet, so without
#   this, peering a spoke would open every port on every hub subnet to it.
# - 4096 DenyInternetOutBound (optional): overrides the default
#   AllowInternetOutBound (65001).
# The default AllowAzureLoadBalancerInBound (65001) is left alone so load
# balancer health probes keep working.

locals {
  nsg_rules = {
    for subnet_key, subnet in var.subnets : subnet_key => merge(
      {
        for rule_name, r in subnet.nsg_rules : rule_name => {
          priority    = r.priority
          direction   = r.direction
          access      = r.access
          protocol    = r.protocol
          ports       = r.destination_port_ranges
          source      = r.direction == "Inbound" ? r.remote_address_prefixes : coalesce(r.local_address_prefixes, [subnet.address_prefix])
          destination = r.direction == "Inbound" ? coalesce(r.local_address_prefixes, [subnet.address_prefix]) : r.remote_address_prefixes
          description = r.description
        }
      },
      {
        AllowSameSubnetInBound = {
          priority    = 4000
          direction   = "Inbound"
          access      = "Allow"
          protocol    = "*"
          ports       = ["*"]
          source      = [subnet.address_prefix]
          destination = [subnet.address_prefix]
          description = "Baseline: traffic between hosts in this subnet."
        }
        DenyVnetInBound = {
          priority    = 4096
          direction   = "Inbound"
          access      = "Deny"
          protocol    = "*"
          ports       = ["*"]
          source      = ["VirtualNetwork"]
          destination = ["*"]
          description = "Baseline: overrides AllowVnetInBound, which admits every peered VNet."
        }
      },
      {
        for k, v in {
          DenyInternetOutBound = {
            priority    = 4096
            direction   = "Outbound"
            access      = "Deny"
            protocol    = "*"
            ports       = ["*"]
            source      = ["*"]
            destination = ["Internet"]
            description = "Baseline: overrides AllowInternetOutBound. Egress must be explicit."
          }
        } : k => v if var.deny_internet_outbound
      },
    )
  }
}

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = var.address_space

  tags = var.tags
}

resource "azurerm_subnet" "this" {
  for_each = var.subnets

  name                 = "snet-${each.key}"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [each.value.address_prefix]

  # Private subnet: VMs get no implicit outbound SNAT ("default outbound
  # access", which Azure is retiring). The provider still defaults this to
  # true, so it's set explicitly. Egress would need a NAT gateway or firewall.
  default_outbound_access_enabled = false

  # Apply NSG rules and route tables to private endpoints in this subnet too,
  # so they don't bypass the default-deny baseline.
  private_endpoint_network_policies = "Enabled"
}

resource "azurerm_network_security_group" "this" {
  for_each = var.subnets

  name                = "nsg-${var.name}-${each.key}"
  resource_group_name = var.resource_group_name
  location            = var.location

  # Inline rules make the NSG authoritative: a rule added by hand in the
  # portal shows up as drift and is removed on the next apply.
  dynamic "security_rule" {
    for_each = local.nsg_rules[each.key]

    content {
      name        = security_rule.key
      description = security_rule.value.description
      priority    = security_rule.value.priority
      direction   = security_rule.value.direction
      access      = security_rule.value.access
      protocol    = security_rule.value.protocol

      source_port_range       = "*"
      destination_port_range  = length(security_rule.value.ports) == 1 ? security_rule.value.ports[0] : null
      destination_port_ranges = length(security_rule.value.ports) > 1 ? security_rule.value.ports : null

      # The singular field accepts service tags; the list field only CIDRs.
      source_address_prefix        = length(security_rule.value.source) == 1 ? security_rule.value.source[0] : null
      source_address_prefixes      = length(security_rule.value.source) > 1 ? security_rule.value.source : null
      destination_address_prefix   = length(security_rule.value.destination) == 1 ? security_rule.value.destination[0] : null
      destination_address_prefixes = length(security_rule.value.destination) > 1 ? security_rule.value.destination : null
    }
  }

  tags = var.tags
}

resource "azurerm_subnet_network_security_group_association" "this" {
  for_each = var.subnets

  subnet_id                 = azurerm_subnet.this[each.key].id
  network_security_group_id = azurerm_network_security_group.this[each.key].id
}
