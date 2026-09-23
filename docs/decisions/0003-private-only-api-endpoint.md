# 0003. Private-only EKS API endpoint

- **Status:** Accepted
- **Date:** 2026-09-23

## Context

An EKS cluster endpoint can be public, private, or both. The default is
public: the Kubernetes API is reachable from the internet and protected only
by authentication (and optional CIDR allowlists). Public API servers are
routinely scanned, and any authn/authz bug or leaked credential is then
exploitable from anywhere.

## Decision

`endpoint_public_access = false`, `endpoint_private_access = true`.

The API server's hostname resolves to ENIs in the private subnets. Only
clients inside the VPC can open a connection, and only if the cluster security
groups allow it: nodes via the EKS-managed security group, the bastion via
`api_client_security_group_ids`.

Humans reach the API through an SSM port-forwarding tunnel on the bastion
([ADR 0004](0004-ssm-over-ssh.md)).

## Consequences

**Good**
- The API isn't reachable from the internet at all, even with stolen credentials.
- Two independent controls: network reachability (security groups) and
  identity (IAM via access entries).

**Costs and limits**
- kubectl needs the bastion tunnel, a VPN, or Direct Connect.
- CI/CD that applies Kubernetes manifests must run inside the VPC (for
  example self-hosted runners) or use a pull-based GitOps agent in the
  cluster, which also can't reach the internet here.
- Terraform must not use the `kubernetes` or `helm` providers, because it
  runs outside the VPC. Everything (add-ons, access entries, node groups) goes
  through the EKS API instead, which is AWS's public control plane, not the
  cluster's Kubernetes API.

## Alternatives considered

| Option | Why not |
|---|---|
| Public + private with `public_access_cidrs` allowlist | Better than open, but home and office IPs change, and the endpoint is still internet-facing. |
| Public only | AWS default; the risk this decision removes. |
