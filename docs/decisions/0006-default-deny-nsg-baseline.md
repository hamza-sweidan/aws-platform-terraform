# 0006. Default-deny NSG baseline and private subnets

- **Status:** Accepted
- **Date:** 2026-09-23

## Context

A new NSG is not empty. Azure adds default rules that can't be deleted:

| Priority | Inbound | Outbound |
|---|---|---|
| 65000 | AllowVnetInBound | AllowVnetOutBound |
| 65001 | AllowAzureLoadBalancerInBound | AllowInternetOutBound |
| 65500 | DenyAllInBound | DenyAllOutBound |

The trap is `AllowVnetInBound`. The `VirtualNetwork` service tag means *this
VNet plus every peered VNet* (and on-premises ranges behind a gateway). As
soon as a spoke is peered, every host in it can reach every port on every hub
subnet, and the hub can reach every spoke, without a single custom rule.

On top of that, `AllowInternetOutBound`, together with Azure's *default
outbound access* (implicit SNAT for VMs without a public IP), gives every VM
internet egress unless someone takes it away.

## Decision

`azure/modules/vnet` gives every subnet its own NSG with a module-owned
baseline, and reserves priorities 4000-4096 for it:

| Priority | Rule | Effect |
|---|---|---|
| 4000 | AllowSameSubnetInBound | Hosts in one subnet can talk to each other. |
| 4096 | DenyVnetInBound | Overrides AllowVnetInBound. East-west traffic must be allowed explicitly at 100-3999. |
| 4096 | DenyInternetOutBound | Overrides AllowInternetOutBound. |

Subnets are also created **private** (`default_outbound_access_enabled =
false`), so there's no implicit SNAT path even if an NSG is detached. The
same thinking as the AWS side's zero-egress VPC ([ADR 0001](0001-no-nat-gateway.md)).

Rules are inline in the NSG resource, which makes Terraform authoritative:
a rule added by hand in the portal is reverted on the next apply.

## Consequences

**Good**
- Peering a new spoke opens nothing by itself. Every allowed flow is an
  explicit, reviewable rule with a description (the environment's traffic
  matrix).
- Spoke-to-spoke traffic is blocked twice: by routing (non-transitive
  peering) and by the NSG.
- Load balancer health probes still work (65001 is left alone).

**Costs and limits**
- Anything that needs the internet (OS updates, package mirrors, Azure PaaS
  over public endpoints) needs an explicit egress design: NAT gateway, Azure
  Firewall, or private endpoints. That's intended, but it's work.
- Priorities 4000-4096 are unavailable to callers; the module validates this.
- NSGs are layer 4 only. Filtering by FQDN needs Azure Firewall.

## Alternatives considered

| Option | Why not |
|---|---|
| Rely on the default rules | AllowVnetInBound makes peering an any-to-any network. |
| One NSG per VNet | A single rule set for app and data tiers. A change for one tier can open the other. |
| Application Security Groups | Good for grouping VMs by role within a subnet. There are no VMs yet; subnet CIDRs are clearer for a network baseline. |
| Separate `azurerm_network_security_rule` resources | Not authoritative: rules added outside Terraform go unnoticed. |
