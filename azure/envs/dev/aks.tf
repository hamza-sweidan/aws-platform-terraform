# Phase 3: a network-isolated private AKS cluster in its own spoke.
# Off by default. enable_aks = true adds ~$0.18/h of resources (two B2als_v2
# nodes, Premium ACR, private endpoints); see azure/README.md.
#
#   aks spoke (10.13.0.0/22) --peering--> hub
#     snet-nodes 10.13.0.0/24: nodes, API server private endpoint, ACR private endpoint
#   ACR Premium, public access off --> aks-managed-mcr cache rule (AKS bootstrap)
#   AKS: outbound_type none, private API, Entra ID only, CNI Overlay + Cilium

data "azurerm_client_config" "current" {}

locals {
  aks_pod_cidr = "10.244.0.0/16"
  aks_nodes_prefix = cidrsubnet(
    var.aks_address_space, 24 - tonumber(split("/", var.aks_address_space)[1]), 0,
  )

  # Registry names are global, lowercase letters and digits only. A hash of
  # the subscription keeps it unique and stable, like the state account.
  acr_name = "acr${replace(var.project, "-", "")}${substr(sha1(var.subscription_id), 0, 8)}"

  aks_admin_object_ids = coalescelist(var.aks_admin_object_ids, [data.azurerm_client_config.current.object_id])
}

resource "azurerm_resource_group" "aks" {
  count = var.enable_aks ? 1 : 0

  name     = "rg-${var.project}-aks-${var.environment}"
  location = var.location
  tags     = local.tags
}

module "aks_spoke" {
  source = "../../modules/vnet"
  count  = var.enable_aks ? 1 : 0

  name                = "${var.project}-aks-${var.environment}"
  resource_group_name = azurerm_resource_group.aks[0].name
  location            = var.location
  address_space       = [var.aks_address_space]

  subnets = {
    nodes = {
      address_prefix = local.aks_nodes_prefix
      nsg_rules = {
        # Azure CNI Overlay: pod-to-pod traffic between nodes keeps pod IPs
        # (10.244.0.0/16), which are outside the subnet and the VirtualNetwork
        # tag. Without these rules the default-deny baseline would drop it,
        # including every DNS query to CoreDNS on another node. Traffic that
        # leaves the cluster is SNAT'd to the node IP and needs nothing extra.
        AllowClusterTrafficInBound = {
          priority                = 100
          direction               = "Inbound"
          protocol                = "*"
          remote_address_prefixes = [local.aks_nodes_prefix, local.aks_pod_cidr]
          local_address_prefixes  = [local.aks_nodes_prefix, local.aks_pod_cidr]
          destination_port_ranges = ["*"]
          description             = "Node and overlay pod traffic inside the cluster."
        }
        AllowClusterTrafficOutBound = {
          priority                = 100
          direction               = "Outbound"
          protocol                = "*"
          remote_address_prefixes = [local.aks_nodes_prefix, local.aks_pod_cidr]
          local_address_prefixes  = [local.aks_nodes_prefix, local.aks_pod_cidr]
          destination_port_ranges = ["*"]
          description             = "Node and overlay pod traffic inside the cluster."
        }
      }
    }
  }

  tags = local.tags
}

module "aks_peering" {
  source = "../../modules/vnet-peering"
  count  = var.enable_aks ? 1 : 0

  hub = {
    id                  = module.hub.id
    name                = module.hub.name
    resource_group_name = module.hub.resource_group_name
    address_space       = module.hub.address_space
  }

  spoke = {
    id                  = module.aks_spoke[0].id
    name                = module.aks_spoke[0].name
    resource_group_name = module.aks_spoke[0].resource_group_name
    address_space       = module.aks_spoke[0].address_space
  }
}

module "acr" {
  source = "../../modules/acr-private"
  count  = var.enable_aks ? 1 : 0

  name                       = local.acr_name
  resource_group_name        = azurerm_resource_group.aks[0].name
  location                   = var.location
  private_endpoint_subnet_id = module.aks_spoke[0].subnet_ids["nodes"]
  virtual_network_id         = module.aks_spoke[0].id
  tags                       = local.tags

  # The tag policy must be in place first: it has to exempt the private
  # endpoint's untagged NIC, or the endpoint is denied.
  depends_on = [module.tag_policy]
}

module "aks" {
  source = "../../modules/aks"
  count  = var.enable_aks ? 1 : 0

  name                  = "aks-${local.name}"
  resource_group_name   = azurerm_resource_group.aks[0].name
  node_resource_group   = "rg-${var.project}-aks-nodes-${var.environment}"
  location              = var.location
  kubernetes_version    = var.aks_kubernetes_version
  subnet_id             = module.aks_spoke[0].subnet_ids["nodes"]
  container_registry_id = module.acr[0].id
  pod_cidr              = local.aks_pod_cidr
  node_count            = var.aks_node_count
  admin_principal_ids   = local.aks_admin_object_ids
  tags                  = local.tags
}
