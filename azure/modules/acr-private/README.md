# acr-private

A private Azure Container Registry: the only image source for the
network-isolated AKS cluster, just as private ECR is for EKS.

| Setting | Why |
|---|---|
| Premium SKU | The only tier with private endpoints and cache rules (~$1.67/day). |
| `public_network_access_enabled = false` | No public endpoint. Clients in the linked VNet reach it through the private endpoint. |
| Private endpoint + `privatelink.azurecr.io` zone | `<name>.azurecr.io` and the regional data endpoint resolve to private IPs inside the VNet. The DNS zone group writes both A records. |
| `aks-managed-mcr` cache rule | `mcr.microsoft.com/*` → `aks-managed-repository/*`. With `outbound_type = "none"`, AKS pulls its own system images (kube-proxy, CoreDNS, Cilium, ...) through this rule during node bootstrap. Microsoft's guide says it must exist before the cluster and must not be modified. |
| No admin user, no anonymous pull | Pulls need Entra ID + RBAC (`AcrPull` for the AKS kubelet identity, assigned in `modules/aks`). |
| Dedicated data endpoints, zone redundancy | Both free on Premium: one FQDN per region for layer downloads, and zone-level resilience. |
| `export_policy_enabled = false` | Images can't be exported out of a registry with public access off. |
| `network_rule_bypass_option = "AzureServices"` | Lets trusted Azure services in, e.g. `az acr import`, which runs inside ACR. That's how workload images are mirrored in without opening the registry. |

## Mirroring workload images

Like `scripts/mirror-image.sh` on the AWS side, but ACR pulls server-side, so
nothing is copied through your laptop:

```bash
az acr import --name <registry> \
  --source docker.io/nginxinc/nginx-unprivileged:1.30-alpine \
  --image mirror/nginx-unprivileged:1.30-alpine
```

## Tests

`tests/acr_private.tftest.hcl` (mocked provider) checks the registry
lockdown, the exact cache-rule contract, the private endpoint and DNS, and
name validation.

## Usage

```hcl
module "acr" {
  source = "../../modules/acr-private"

  name                       = "acrhubspoke1234abcd"
  resource_group_name        = azurerm_resource_group.aks.name
  location                   = "germanywestcentral"
  private_endpoint_subnet_id = module.aks_spoke.subnet_ids["nodes"]
  virtual_network_id         = module.aks_spoke.id
  tags                       = local.tags
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
| [azurerm_container_registry.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/container_registry) | resource |
| [azurerm_container_registry_cache_rule.aks_mcr](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/container_registry_cache_rule) | resource |
| [azurerm_private_dns_zone.acr](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_dns_zone) | resource |
| [azurerm_private_dns_zone_virtual_network_link.acr](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_dns_zone_virtual_network_link) | resource |
| [azurerm_private_endpoint.acr](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_endpoint) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| location | Azure region. | `string` | n/a | yes |
| name | Registry name: globally unique, 5-50 lowercase letters and digits (no hyphens). Becomes <name>.azurecr.io. | `string` | n/a | yes |
| private\_endpoint\_subnet\_id | Subnet for the registry's private endpoint (its private IPs for the registry and data endpoints). | `string` | n/a | yes |
| resource\_group\_name | Resource group for the registry, its private endpoint and the private DNS zone. | `string` | n/a | yes |
| virtual\_network\_id | VNet whose clients resolve <name>.azurecr.io to the private endpoint (privatelink.azurecr.io is linked to it). | `string` | n/a | yes |
| aks\_bootstrap\_cache\_rule | Create the aks-managed-mcr cache rule (mcr.microsoft.com/* -> aks-managed-repository/*) a network-isolated AKS cluster bootstraps from. | `bool` | `true` | no |
| tags | Tags for every taggable resource. azurerm has no provider default\_tags. | `map(string)` | `{}` | no |
| untagged\_retention\_days | Days before untagged manifests are purged. | `number` | `7` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| id | Registry resource ID (bootstrap\_profile.container\_registry\_id, AcrPull scope). |
| login\_server | Registry login server, e.g. <name>.azurecr.io. |
| name | Registry name. |
| private\_endpoint\_id | Private endpoint ID. |
<!-- END_TF_DOCS -->
