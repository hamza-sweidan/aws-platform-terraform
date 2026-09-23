# 0005. Azure hub-and-spoke with native VNet peering

- **Status:** Accepted
- **Date:** 2026-09-23

## Context

The Azure side needs a network that several workloads can share: common
services in one place (DNS today; later a firewall, Bastion or a VPN gateway),
and workloads kept apart from each other by default. It should cost nothing
while idle, like everything else in this lab.

## Decision

A hub VNet and two spoke VNets, each spoke peered to the hub with native VNet
peering (`azure/modules/vnet-peering`). Details:

- **One resource group per VNet.** In a landing zone each spoke belongs to a
  different team, so the resource group is the RBAC and cost boundary.
- **Both peering links in one module**, so a spoke can never be half-peered.
- **No firewall or gateway yet**, but the hub's first /24 is reserved for
  `AzureFirewallSubnet`, `AzureBastionSubnet` and `GatewaySubnet`. Adding one
  later needs no re-addressing.
- **Address plan that can't collide:** hub 10.10.0.0/22, spokes 10.11/22 and
  10.12/22. None of it overlaps the AWS VPC (10.0.0.0/16). The environment
  rejects overlapping ranges at plan time.

## Consequences

**Good**
- **Isolation by default.** Peering is not transitive, so spoke1 has no route
  to spoke2. The NSGs deny it as well (ADR 0006).
- **$0 while idle.** VNets, NSGs, peering and Azure Policy have no hourly
  charge. Peering is billed only on traffic: $0.01/GB each way within a region.
- Adding a spoke is one map entry (`var.spokes`).

**Costs and limits**
- Spoke-to-spoke traffic, when it's wanted, needs a hub firewall or NVA,
  route tables in the spokes, and `allow_forwarded_traffic` on the spoke
  links. Azure Firewall Basic lists at $0.395/h and Standard at $1.25/h in
  Germany West Central.
- Every spoke adds two peering links to manage. At dozens of spokes, Azure
  Virtual Network Manager or Virtual WAN takes that work away.
- Address planning has to be done up front. A peered VNet's address space can
  grow, but only with a peering re-sync (handled by `triggers`).

## Alternatives considered

| Option | Why not |
|---|---|
| One flat VNet with a subnet per workload | No isolation boundary beyond NSGs, and every team shares one VNet's RBAC and lifecycle. |
| Full-mesh peering | n·(n-1)/2 peerings. Every workload can reach every other, which is the opposite of the goal. |
| Azure Virtual WAN | Microsoft-managed hub with transitive routing built in, but a standard hub is $0.25/h (~$180/month) before any traffic. The right answer at enterprise scale; overkill for three VNets. |
| Azure Virtual Network Manager | Manages hub-and-spoke peering at scale from one config. Worth it at many spokes; here it would hide the peering mechanics this repo is meant to show. |
