# 0010. Network-isolated private AKS

- **Status:** Accepted
- **Date:** 2026-09-23

## Context

Phase 1 built a private EKS cluster with zero internet egress: no NAT
gateway, VPC endpoints for AWS APIs, images only from private ECR. Phase 3
builds the same thing on Azure in a spoke of the hub-and-spoke network. A
default AKS cluster has unrestricted outbound internet access through a
load balancer, and its nodes pull system images from Microsoft's public
registry (MCR).

## Decision

A **network-isolated** private AKS cluster (`azure/modules/aks`), with a
bring-your-own private ACR (`azure/modules/acr-private`), behind an
`enable_aks` toggle:

| Concern | Choice |
|---|---|
| Egress | `outbound_type = "none"`: AKS creates no outbound path. The subnet is private (no default outbound access) and its NSG denies Internet. |
| System images | `bootstrap_profile.artifact_source = "Cache"`: nodes pull kube-proxy, CoreDNS, Cilium etc. through the ACR's `aks-managed-mcr` cache rule (`mcr.microsoft.com/*` → `aks-managed-repository/*`), over a private endpoint. |
| Registry | Premium ACR, public network access off, no admin user or anonymous pull, private endpoint + `privatelink.azurecr.io`. |
| API server | Private cluster, no public FQDN. kubectl runs *inside* the cluster through `az aks command invoke`: no jump host, no VPN. |
| Identity | Local accounts off; Azure RBAC for Kubernetes. User-assigned control plane and kubelet identities, so AcrPull and Network Contributor exist *before* nodes try to pull. |
| Networking | Azure CNI Overlay + Cilium (dataplane and NetworkPolicy). The node subnet NSG allows the pod CIDR, because pod-to-pod traffic between nodes keeps pod IPs. |
| Size | 2 × Standard_B2als_v2, Free tier control plane, no automatic upgrades (see below). |

Two supporting changes to Phase 2:

- **Tag policy exemption for private endpoint NICs.** Azure creates the ACR
  private endpoint's NIC itself, untagged, so the Deny would block it. The
  exemption checks `networkInterfaces/privateEndpoint`, so other NICs are
  still covered (ADR 0007).
- **`local_address_prefixes` in the vnet module,** so NSG rules can include
  addresses that live outside the subnet (the overlay pod CIDR).

## Consequences

**Good**
- The cluster has no route to the internet, and every image comes from a
  registry this repository controls: the same supply-chain story as EKS.
- No secret or local kubeconfig admin exists. Access is Entra ID and
  auditable.
- Off costs $0. On costs about $0.18/h, and the environment around it doesn't change.

**Costs and limits**
- **No automatic upgrades.** Every AKS upgrade adds a surge node, and a Free
  Trial's 4-vCPU quota is used up by two 2-vCPU nodes. The lab is rebuilt
  per session instead. Production would use the `patch` + `NodeImage`
  channels, a maintenance window and quota headroom.
- **Add-ons that need egress don't work:** Azure Monitor, the Azure Policy
  add-on, Defender. Each would need a private link scope or allowed egress.
  The corresponding checkov findings are justified inline.
- **The cache rule is a contract.** Microsoft's guide says it must exist
  before the cluster and must not be modified. The ACR module owns it,
  and a test pins its exact name and repositories.
- Workload images are mirrored with `az acr import`. The registry has no
  public endpoint, so its data-plane API (and digest lookups) isn't reachable
  from a laptop; the demo deploys by tag. Production would enable ACR tag
  locking or pin digests from the source registry.

## Alternatives considered

| Option | Why not |
|---|---|
| Default AKS with Azure Firewall egress filtering | Firewall Basic is $0.395/h on its own, and the FQDN allowlist is a moving target. Right for clusters that *need* egress. |
| AKS-managed ACR for bootstrapping | Simpler (AKS creates it), but this repo mirrors workload images too, and one registry we own is the better parallel to ECR. |
| API Server VNet Integration instead of a private endpoint | Needs a delegated subnet, and command invoke already solves laptop access. |
| `outbound_type = "block"` | Still preview; `none` is GA. |
| System-assigned identities | Their principals don't exist until the cluster does, so AcrPull couldn't be granted before nodes need it. |
