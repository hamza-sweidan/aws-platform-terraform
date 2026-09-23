# dev environment: a hub VNet, two spoke VNets peered to it, per-subnet NSGs
# and a Deny policy for required tags. The environment only decides names,
# the address plan and who may talk to whom; resource logic lives in modules/.
#
# Traffic allowed on top of the default-deny NSG baseline:
#   spoke/*   -> hub shared   DNS (53)      e.g. a DNS forwarder in the hub
#   hub shared -> spoke app   HTTPS (443)   e.g. management or a hub proxy
#   spoke app -> spoke data   Postgres (5432), same spoke only
# Spoke-to-spoke: no route (peering isn't transitive), and the NSGs deny it too.

locals {
  name = "${var.project}-${var.environment}"

  # azurerm has no provider default_tags. Every resource gets these passed
  # explicitly, and the tag policy denies anything that misses one.
  tags = {
    Project     = var.project
    Environment = var.environment
    Owner       = var.owner
    ManagedBy   = "Terraform"
  }

  # Hub address plan (/22 by default):
  #   first /24  reserved: AzureFirewallSubnet /26, AzureBastionSubnet /26,
  #              GatewaySubnet /27. Not created; kept free so a firewall or
  #              gateway can be added later without re-addressing.
  #   second /24 snet-shared: shared services the spokes consume
  #   last /23   free
  hub_shared_prefix = cidrsubnet(var.hub_address_space, 24 - tonumber(split("/", var.hub_address_space)[1]), 1)

  # Each spoke: first quarter app, second quarter data, second half free.
  spoke_subnets = {
    for k, s in var.spokes : k => {
      app  = cidrsubnet(s.address_space, 2, 0)
      data = cidrsubnet(s.address_space, 2, 1)
    }
  }
}

resource "azurerm_resource_group" "hub" {
  name     = "rg-${var.project}-hub-${var.environment}"
  location = var.location
  tags     = local.tags
}

# One resource group per spoke: in a landing zone each spoke belongs to a
# different team, and the resource group is the RBAC and cost boundary.
resource "azurerm_resource_group" "spoke" {
  for_each = var.spokes

  name     = "rg-${var.project}-${each.key}-${var.environment}"
  location = var.location
  tags     = local.tags
}

module "hub" {
  source = "../../modules/vnet"

  name                = "${var.project}-hub-${var.environment}"
  resource_group_name = azurerm_resource_group.hub.name
  location            = var.location
  address_space       = [var.hub_address_space]

  subnets = {
    shared = {
      address_prefix = local.hub_shared_prefix
      nsg_rules = {
        AllowDnsFromSpokes = {
          priority                = 100
          direction               = "Inbound"
          protocol                = "*" # DNS uses UDP and falls back to TCP
          remote_address_prefixes = concat([for s in values(var.spokes) : s.address_space], var.enable_aks ? [var.aks_address_space] : [])
          destination_port_ranges = ["53"]
          description             = "Spokes resolve names through shared DNS in the hub."
        }
      }
    }
  }

  tags = local.tags
}

module "spoke" {
  source   = "../../modules/vnet"
  for_each = var.spokes

  name                = "${var.project}-${each.key}-${var.environment}"
  resource_group_name = azurerm_resource_group.spoke[each.key].name
  location            = var.location
  address_space       = [each.value.address_space]

  subnets = {
    app = {
      address_prefix = local.spoke_subnets[each.key].app
      nsg_rules = {
        AllowHttpsFromHubShared = {
          priority                = 100
          direction               = "Inbound"
          protocol                = "Tcp"
          remote_address_prefixes = [local.hub_shared_prefix]
          destination_port_ranges = ["443"]
          description             = "Management and proxied traffic from hub shared services."
        }
      }
    }
    data = {
      address_prefix = local.spoke_subnets[each.key].data
      nsg_rules = {
        AllowPostgresFromApp = {
          priority                = 100
          direction               = "Inbound"
          protocol                = "Tcp"
          remote_address_prefixes = [local.spoke_subnets[each.key].app]
          destination_port_ranges = ["5432"]
          description             = "Only this spoke's app tier reaches its database tier."
        }
      }
    }
  }

  tags = local.tags
}

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

module "tag_policy" {
  source = "../../modules/tag-policy"

  name          = "require-tags-${local.name}"
  required_tags = keys(local.tags)
  effect        = var.tag_policy_effect

  resource_group_ids = merge(
    { hub = azurerm_resource_group.hub.id },
    { for k, rg in azurerm_resource_group.spoke : k => rg.id },
    { for rg in azurerm_resource_group.aks : "aks" => rg.id },
  )
}
