# 0008. Azure state in Blob Storage with Entra ID-only access

- **Status:** Accepted
- **Date:** 2026-09-23

## Context

The Azure configurations need remote state with locking, like the AWS side
([ADR 0002](0002-s3-native-state-locking.md)). The usual Azure setup is a
storage account plus the `azurerm` backend authenticated with an *account
key*. An account key is a shared secret with full control of every blob in
the account. It never expires, and requests signed with it don't identify who
made them.

## Decision

`azure/bootstrap` creates a storage account that accepts **Entra ID only**:

- `shared_access_key_enabled = false`: account keys and account SAS tokens
  are rejected. The backend uses `use_azuread_auth = true` with your `az login`.
- **Data-plane RBAC:** the operator gets *Storage Blob Data Contributor* on
  the `tfstate` container only. Owner on the subscription is not enough, by
  design (see below).
- **Network:** public endpoint with firewall default `Deny`, allowing only
  the operator's IPs. Terraform enforces the `Deny` and seeds the allowlist,
  then ignores it (`ignore_changes`). `scripts/azure-state-firewall.sh` adds
  the current IP when the operator moves between networks. Firewall changes go
  through the ARM control plane, which the storage firewall doesn't gate, so
  there's no lock-out.
- **Recovery:** blob versioning plus 30-day soft delete for blobs and
  containers, GZRS replication, and `prevent_destroy` on the account and
  container.
- **Locking:** native blob leases. `plan` and `apply` lease the state blob and
  release it at the end. Nothing extra to create.

### Why Owner isn't enough

Azure separates the **control plane** (`Microsoft.Storage/storageAccounts/*`:
create the account, change settings, *list keys*) from the **data plane**
(`.../blobServices/containers/blobs/*` *data actions*: read and write blobs).
Owner has every control-plane action but no data actions. With Shared Key
enabled, Owner could still read state by calling `listKeys` and using the key.
With Shared Key disabled, that route is closed, and blob access requires a
data-plane role that shows up by name in the audit log.

## Consequences

**Good**
- No long-lived secret exists that could leak from a laptop, CI log or
  `backend.hcl`.
- Every state read and write is authorised as a named identity.
- A CI pipeline later gets its own role assignment through OIDC workload
  identity federation, with no stored secret.

**Costs and limits**
- A new role assignment takes a few minutes to reach the data plane. The first
  `terraform init` right after bootstrap can fail with 403 (runbook §1).
- A new network needs `scripts/azure-state-firewall.sh allow` before the
  first `terraform init` there. Old IPs stay allowed until revoked (`reset`
  keeps only the current one).
- Two tools need to know Shared Key is off: the provider (`storage_use_azuread
  = true`) and the backend (`use_azuread_auth = true`).
- Cost: a few KB of GZRS storage plus a few thousand operations a month, well
  under $0.10.

## Alternatives considered

| Option | Why not |
|---|---|
| Account key in `backend.hcl` or `ARM_ACCESS_KEY` | A permanent shared secret with full account access. |
| SAS token | Better scoped and expiring, but still a bearer secret that has to be stored and rotated. |
| Private endpoint, no public access | The laptop has no private path into Azure. It needs a VPN or a runner inside the VNet first. |
| Reuse the AWS S3 bucket | Works (Terraform doesn't care which cloud the state is in), but every Azure plan would also need AWS credentials. |
| HCP Terraform | A good managed option, but it moves state and runs out of the account this repo is demonstrating. |
