# A private Azure Container Registry: the only image source for a
# network-isolated AKS cluster, like private ECR for the EKS cluster.
#
# - Premium SKU: the only tier with private endpoints and cache rules.
# - Public network access off. Clients in the linked VNet reach it through a
#   private endpoint; <name>.azurecr.io resolves to private IPs via the
#   privatelink.azurecr.io zone.
# - The aks-managed-mcr cache rule lets AKS pull its own system images
#   (mcr.microsoft.com/*) through this registry during node bootstrap.
#   Microsoft's guide says the rule must exist before the cluster and must
#   not be modified.
# - No admin user and no anonymous pull: access is Entra ID + RBAC only.

resource "azurerm_container_registry" "this" {
  #checkov:skip=CKV_AZURE_163:Vulnerability scanning is Microsoft Defender for Containers, billed per image and node. Out of scope for a lab; images are pinned by digest.
  #checkov:skip=CKV_AZURE_165:Geo-replication adds a second billed registry. One region, zone-redundant, is enough here.
  #checkov:skip=CKV_AZURE_166:Quarantine needs a scanner to release images; without Defender every push would stay quarantined.
  #checkov:skip=CKV_AZURE_164:Content trust (Docker Notary v1) is retired in ACR in favour of Notation signing, which needs its own key management.
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Premium"

  admin_enabled                 = false
  anonymous_pull_enabled        = false
  public_network_access_enabled = false
  # Trusted Azure services only (e.g. `az acr import`, which runs inside ACR).
  network_rule_bypass_option = "AzureServices"
  # With public access off, images can't be exported out of the registry.
  export_policy_enabled = false
  # Layer downloads go to <name>.<region>.data.azurecr.io instead of a shared
  # *.blob.core.windows.net host, so egress rules can name one FQDN. Free.
  data_endpoint_enabled = true
  # Zone redundancy is free on Premium in regions with zones.
  zone_redundancy_enabled  = true
  retention_policy_in_days = var.untagged_retention_days

  tags = var.tags
}

resource "azurerm_container_registry_cache_rule" "aks_mcr" {
  count = var.aks_bootstrap_cache_rule ? 1 : 0

  # Name and repositories as Microsoft's network-isolated AKS guide requires.
  name                  = "aks-managed-mcr"
  container_registry_id = azurerm_container_registry.this.id
  source_repo           = "mcr.microsoft.com/*"
  target_repo           = "aks-managed-repository/*"
}

resource "azurerm_private_dns_zone" "acr" {
  name                = "privatelink.azurecr.io"
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "acr" {
  name                 = "link-${var.name}"
  private_dns_zone_id  = azurerm_private_dns_zone.acr.id
  virtual_network_id   = var.virtual_network_id
  registration_enabled = false
  tags                 = var.tags
}

resource "azurerm_private_endpoint" "acr" {
  name                          = "pe-${var.name}"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  subnet_id                     = var.private_endpoint_subnet_id
  custom_network_interface_name = "nic-pe-${var.name}"

  private_service_connection {
    name                           = "psc-${var.name}"
    private_connection_resource_id = azurerm_container_registry.this.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  # Creates the A records for both <name>.azurecr.io and the regional data
  # endpoint <name>.<region>.data.azurecr.io in the private zone.
  private_dns_zone_group {
    name                 = "acr"
    private_dns_zone_ids = [azurerm_private_dns_zone.acr.id]
  }

  tags = var.tags
}
