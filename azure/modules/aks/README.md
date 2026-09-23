# aks

A **network-isolated private AKS cluster**: the Azure counterpart of
[`modules/eks`](../../../modules/eks). There's no egress path at all. Nodes
bootstrap from a private ACR, the API server is private, and access is
Entra ID only.

## EKS ↔ AKS, side by side

| Concern | EKS (Phase 1) | AKS (this module) |
|---|---|---|
| No internet egress | No NAT gateway; VPC endpoints for AWS APIs | `outbound_type = "none"`: AKS creates no egress path |
| System images | Pulled from ECR via `ecr.api`/`ecr.dkr` endpoints + S3 gateway | `bootstrap_profile.artifact_source = "Cache"`: pulled through the private ACR's `aks-managed-mcr` cache rule |
| Workload images | `scripts/mirror-image.sh` → private ECR | `az acr import` → private ACR |
| API server | `endpoint_public_access = false` | `private_cluster_enabled = true`, no public FQDN |
| kubectl from a laptop | SSM port-forward through a bastion | `az aks command invoke`: runs kubectl inside the cluster via ARM; no jump host |
| Who's admin | Access entries, no `aws-auth` | Azure RBAC for Kubernetes, `local_account_disabled = true` |
| Node permissions | Node role: WorkerNode + ECR PullOnly | Kubelet identity: **AcrPull** on one registry |
| Pod networking | VPC CNI (pods get VPC IPs) + IRSA | Azure CNI Overlay (pods from `pod_cidr`) + Cilium; workload identity enabled |

## Identities

| Identity | Role | Scope | Why |
|---|---|---|---|
| Control plane (user-assigned) | Network Contributor | Node subnet | Join node NICs and the API server private endpoint to our subnet (BYO VNet) |
| Control plane | Managed Identity Operator | Kubelet identity | Attach the custom kubelet identity to the node VMs |
| Kubelet (user-assigned) | AcrPull | The registry | Pull system and workload images; nothing else |
| Admins (`admin_principal_ids`) | Azure Kubernetes Service RBAC Cluster Admin | The cluster | The only way in once local accounts are off |

User-assigned identities, not system-assigned, so the roles can be granted
*before* the cluster exists. Nodes pull through the registry while the
cluster is being created, and a system-assigned kubelet identity wouldn't
have AcrPull yet.

## Sized for a Free Trial subscription

- **2 × Standard_B2als_v2** (2 vCPU, 4 GiB, ~$0.043/h each): the smallest size
  AKS accepts for a system pool. Together they use the trial's whole
  4-vCPU quota.
- **No automatic upgrades.** Every upgrade adds a surge node, and there's no
  quota for a third one. This lab cluster is destroyed after each session
  and rebuilt on the pinned version. Production would use `patch` +
  `NodeImage` channels with a maintenance window and quota headroom.
- **32 GB managed OS disks** instead of the 128 GB default. B-series has no
  local disk for ephemeral OS disks.
- **Free tier** control plane: no SLA, $0.

## Networking notes

- Pods get IPs from `pod_cidr` (10.244.0.0/16), outside the VNet. Traffic
  *leaving* the cluster is SNAT'd to the node IP. Pod-to-pod traffic keeps
  pod IPs, so the node subnet's NSG must allow the pod CIDR (the dev
  environment does, with `local_address_prefixes`).
- `service_cidr` 172.16.0.0/16 sits outside 10.0.0.0/8, so it can't collide
  with the AWS VPC or any hub/spoke range.

## Tests

`tests/aks.tftest.hcl` (mocked provider) checks the isolation settings
(`outbound_type`, bootstrap cache, private API), Entra-only access,
least-privilege role scopes, node sizing and input validation.

## Usage

```hcl
module "aks" {
  source = "../../modules/aks"

  name                  = "aks-hubspoke-dev"
  resource_group_name   = azurerm_resource_group.aks.name
  node_resource_group   = "rg-hubspoke-aks-nodes-dev"
  location              = "germanywestcentral"
  subnet_id             = module.aks_spoke.subnet_ids["nodes"]
  container_registry_id = module.acr.id
  admin_principal_ids   = [data.azurerm_client_config.current.object_id]
  tags                  = local.tags
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
| [azurerm_kubernetes_cluster.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/kubernetes_cluster) | resource |
| [azurerm_role_assignment.cluster_admin](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.control_plane_kubelet_operator](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.control_plane_subnet](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.kubelet_acr_pull](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_user_assigned_identity.control_plane](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/user_assigned_identity) | resource |
| [azurerm_user_assigned_identity.kubelet](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/user_assigned_identity) | resource |
| [azurerm_client_config.current](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/client_config) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| admin\_principal\_ids | Entra object IDs (users or groups) that get Azure Kubernetes Service RBAC Cluster Admin. Local accounts are disabled, so this is the only way in. | `list(string)` | n/a | yes |
| container\_registry\_id | Private ACR the cluster bootstraps from (outbound\_type = none) and pulls workload images from. Must already have the aks-managed-mcr cache rule and a private endpoint in the cluster VNet. | `string` | n/a | yes |
| location | Azure region. | `string` | n/a | yes |
| name | Cluster name, also used for its identities and DNS prefix. | `string` | n/a | yes |
| node\_resource\_group | Name of the AKS-managed resource group for node VMs, disks and the API server private endpoint (created by AKS). | `string` | n/a | yes |
| resource\_group\_name | Resource group for the cluster and its identities. | `string` | n/a | yes |
| subnet\_id | Subnet for the nodes (and the API server private endpoint AKS creates). | `string` | n/a | yes |
| dns\_service\_ip | ClusterIP for CoreDNS; must be inside service\_cidr. | `string` | `"172.16.0.10"` | no |
| kubernetes\_version | Kubernetes minor version. Pinned to the version AKS marks default in the region, so plans stay stable. | `string` | `"1.35"` | no |
| node\_count | Nodes in the system pool. | `number` | `2` | no |
| node\_vm\_size | Node VM size. The default is the smallest size AKS accepts for a system pool (2 vCPU, 4 GiB). | `string` | `"Standard_B2als_v2"` | no |
| os\_disk\_size\_gb | Managed OS disk size per node. 32 GB bills as a small Standard SSD tier instead of the 128 GB default. | `number` | `32` | no |
| pod\_cidr | Azure CNI Overlay pod CIDR. Must not overlap any VNet the cluster can reach. | `string` | `"10.244.0.0/16"` | no |
| service\_cidr | Kubernetes Service CIDR. Chosen outside 10.0.0.0/8 so it can't collide with the AWS VPC or any hub/spoke range. | `string` | `"172.16.0.0/16"` | no |
| tags | Tags for the cluster, node pool and identities. | `map(string)` | `{}` | no |
| zones | Availability zones for the nodes. Empty for a regional (non-zonal) pool. | `list(string)` | <pre>[<br/>  "1",<br/>  "2"<br/>]</pre> | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| id | Cluster resource ID. |
| kubelet\_principal\_id | Object ID of the kubelet identity (holds AcrPull on the registry). |
| name | Cluster name. |
| node\_resource\_group | AKS-managed resource group holding the node VMs and the API server private endpoint. |
| oidc\_issuer\_url | OIDC issuer URL for workload identity federation. |
| private\_fqdn | Private API server FQDN (resolves only inside the cluster VNet). |
<!-- END_TF_DOCS -->
