# Runbook: Azure hub-and-spoke

Likely failures in `azure/` and how to diagnose each. The AWS runbook is
[runbook.md](runbook.md). Commands assume bash and a logged-in `az` CLI:

```bash
SA=$(terraform -chdir=azure/bootstrap output -raw storage_account_name)
RG_STATE=$(terraform -chdir=azure/bootstrap output -raw resource_group_name)
ME=$(az ad signed-in-user show --query id -o tsv)
```

---

## 1. `terraform init` fails with 403 on the state account

**Symptoms.** `terraform init -backend-config=backend.hcl` in `azure/envs/dev`
fails with `Failed to get existing workspaces` and a 403. The error code tells
you which cause it is:

| Error code | Cause | Fix |
|---|---|---|
| `AuthorizationPermissionMismatch` | Your identity has no data-plane role on the container yet. A new role assignment takes a few minutes to reach the storage data plane. | Wait 5-10 minutes after the bootstrap apply and retry. If it persists, check the assignment (below). |
| `AuthorizationFailure` / *This request is not authorized to perform this operation* | Your public IP isn't in the storage firewall. It changes with ISP, VPN or network. | `scripts/azure-state-firewall.sh allow`, wait a minute, retry. Terraform ignores the allowlist after creation, so the next bootstrap apply won't undo it. |
| `KeyBasedAuthenticationNotPermitted` | Something is trying to use the account key: `use_azuread_auth` missing from the backend, or `ARM_ACCESS_KEY` set in the shell. | Keep `use_azuread_auth = true` in `versions.tf`; `unset ARM_ACCESS_KEY ARM_SAS_TOKEN`. |

**Diagnose.**

```bash
# Can you list the container as yourself (Entra ID, no key)?
az storage blob list --account-name "$SA" -c tfstate --auth-mode login -o table

# Is your current IP in the firewall? (exit code 2 if not)
scripts/azure-state-firewall.sh status

# Do you hold the data-plane role on the container?
az role assignment list --assignee "$ME" --all \
  --query "[?roleDefinitionName=='Storage Blob Data Contributor'].scope" -o tsv
```

**Why Owner doesn't help:** Owner is a control-plane role with no blob *data
actions*, and Shared Key is disabled, so there's no key to fall back on. See
[ADR 0008](decisions/0008-azure-state-entra-id-only.md).

---

## 2. `MissingSubscriptionRegistration` during plan or apply

**Symptoms.** `The subscription is not registered to use namespace
'Microsoft.Network'` (or `Microsoft.Storage`, `Microsoft.Consumption`).

**Why it happens here.** azurerm 5.0 changed `resource_provider_registrations`
to `none`: the provider no longer registers ~60 Resource Providers on
startup. A fresh subscription has many of them unregistered. This repo lists
the ones it needs in `resource_providers_to_register`, which requires
permission to register them (Owner or Contributor on the subscription).

**Diagnose and fix.**

```bash
az provider show -n Microsoft.Network --query registrationState -o tsv   # expect Registered
az provider register -n Microsoft.Network --wait                          # if you lack rights for the provider to do it
```

If a new resource type is added later, add its namespace to
`resource_providers_to_register` in that root module's `versions.tf`.

---

## 3. `RequestDisallowedByPolicy` on apply

**Symptoms.** Apply fails on one resource with `RequestDisallowedByPolicy`,
naming the assignment `require-tags-hubspoke-dev-<rg>` and the message
*Every resource here needs these tags...*.

**Why it happens here.** That's the tag policy working: the resource is
missing a tag or has an empty one. azurerm has no `default_tags`, so a
resource block without `tags = var.tags` / `local.tags` lands untagged.

**Diagnose.**

```bash
# The failing resource is in the error. Check what Terraform would send:
terraform plan -no-color | grep -A12 '<resource address>' | grep -A6 'tags'

# Existing non-compliant resources (created before the assignment, or while it propagated)
az policy state list -g rg-hubspoke-hub-dev --filter "complianceState eq 'NonCompliant'" \
  --query "[].{resource:resourceId, policy:policyDefinitionName}" -o table
```

**Fix.** Add the missing `tags` argument in the module. Don't weaken the
policy to get an apply through. If you need to see *what would* be denied
first (for example, when adopting existing resources), set
`tag_policy_effect = "Audit"`, apply, review the compliance results, then
switch back to `Deny`.

A resource created by hand in the portal fails the same way. That's
intended: add the four tags in the portal's *Tags* step.

---

## 4. Peering not `Connected`

**Diagnose.**

```bash
az network vnet peering list -g rg-hubspoke-hub-dev --vnet-name vnet-hubspoke-hub-dev \
  --query "[].{name:name, state:peeringState, sync:peeringSyncLevel, remote:remoteAddressSpace.addressPrefixes}" -o table
```

| State | Cause | Fix |
|---|---|---|
| `Initiated` | Only one of the two links exists. Someone deleted the other side outside Terraform. | `terraform apply` recreates it. The module always manages both sides. |
| `Disconnected` | The remote VNet was deleted and recreated. The surviving link points at a VNet ID that no longer exists. | `terraform apply -replace='module.peering["spoke1"].azurerm_virtual_network_peering.hub_to_spoke'` (and the spoke side). |
| `Connected` but sync `LocalNotInSync` / `RemoteNotInSync` | An address range was added to a peered VNet. | Apply again. The `triggers` on each link re-sync it. Manually: `az network vnet peering sync`. |
| Create fails with `VnetAddressSpacesOverlap` | Two VNets share address space. | Normally caught at plan by the `var.spokes` validation. If it isn't, check address spaces added outside Terraform. |

---

## 5. Traffic between subnets doesn't flow (or flows when it shouldn't)

This lab creates no VMs, so there's nothing to send traffic yet. When
workloads arrive:

- **Spoke to spoke is blocked by design.** There is no route (peering isn't
  transitive), and `DenyVnetInBound` denies it too. To allow it, route it
  through a hub firewall ([ADR 0005](decisions/0005-hub-and-spoke-with-vnet-peering.md)).
- **Anything not in the traffic matrix is denied** by `DenyVnetInBound`
  (4096). Add a rule at 100-3999 in `azure/envs/dev/main.tf`.

With a VM in place, Network Watcher answers "which rule decided this?":

```bash
# Which NSG rule allows or denies this exact flow?
az network watcher test-ip-flow --vm <vm-id> --direction Inbound --protocol TCP \
  --local 10.11.1.4:5432 --remote 10.11.0.4:50000

# Effective rules (subnet + NIC NSGs merged) and effective routes on a NIC
az network nic list-effective-nsg -g <rg> -n <nic>
az network nic show-effective-route-table -g <rg> -n <nic> -o table
```

---

## 6. `terraform destroy` fails

| Error | Cause | Fix |
|---|---|---|
| `the Resource Group still contains Resources` | The provider's default `prevent_deletion_if_contains_resources` refuses to delete a group holding something Terraform doesn't manage (e.g. a leftover `nsg-policy-test` from the verify step). | `az resource list -g <rg> -o table`, delete the stray resource, destroy again. |
| `Instance cannot be destroyed` for the state account or container | `prevent_destroy` in `azure/bootstrap`, on purpose. | Only when tearing down for good: remove `prevent_destroy`, then destroy bootstrap *last*. |

---

## 7. State lock left behind

`Error acquiring the state lock ... state blob is already locked` after a
crashed or cancelled run. The lock is a **lease on the state blob**. Confirm
nobody else is running Terraform, then:

```bash
terraform force-unlock <LOCK_ID>     # ID from the error message
# If that fails, break the lease directly (Entra ID auth):
az storage blob lease break --account-name "$SA" -c tfstate -b envs/dev/terraform.tfstate --auth-mode login
```

---

## 8. Pull request plan (CI) fails

The `terraform-plan` workflow's Azure job logs in as the
`id-hubspoke-github-plan` managed identity through GitHub OIDC, lets the
runner's IP through the state firewall, plans, and removes the IP again
([ADR 0009](decisions/0009-pull-request-plans-with-oidc.md)).

| Error in the job log | Cause | Fix |
|---|---|---|
| `AADSTS70021` / `AADSTS700213`: no matching federated identity record | The token's subject isn't `repo:<owner>@<owner-id>/<repo>@<repo-id>:pull_request`: wrong trigger, fork, renamed repository, or wrong `github_repository_ids`. The error message shows the subject GitHub presented. | Compare it with `gh api repos/OWNER/NAME/actions/oidc/customization/sub`, fix `github_repository` / `github_repository_ids` in `azure/bootstrap/terraform.tfvars`, apply bootstrap. |
| `AuthorizationFailed` on `storageAccounts/write` in the firewall step | The custom firewall role isn't assigned yet, or RBAC hasn't propagated (minutes after bootstrap). | Re-run the job; check `az role assignment list --assignee <client id> --all`. |
| `RequestDisallowedByPolicy` in the firewall step, naming `deny-state-*` | The guardrail policy rejected the network-rule update. That only happens if the request would weaken the account, or if Azure evaluated the partial update on its own. | Run `scripts/azure-state-firewall.sh status`. If the account is healthy, set `state_guardrail_effect = "Audit"` in `azure/bootstrap` and apply. |
| `terraform init` retries, then `AuthorizationFailure` (403) | The new firewall rule hadn't reached the storage front ends within ~2 minutes. | Re-run the job. |
| Plan fails with `AuthorizationFailed` on a resource read | The identity's Reader assignment is missing or still propagating. | Same as above; Reader is on the whole subscription. |

A job killed before its last step leaves its runner IP in the firewall. Clean
up with `scripts/azure-state-firewall.sh reset` (keeps only your current IP).

---

## 9. AKS (`enable_aks = true`) fails to create or nodes stay NotReady

The cluster is network-isolated ([ADR 0010](decisions/0010-network-isolated-private-aks.md)):
every image comes through the private ACR, and nothing can reach the internet.

```bash
RG=rg-hubspoke-aks-dev AKS=aks-hubspoke-dev ACR=$(terraform -chdir=azure/envs/dev output -raw acr_name)
az aks show -g $RG -n $AKS --query "{state:provisioningState, power:powerState.code, outbound:networkProfile.outboundType, artifacts:bootstrapProfile.artifactSource}" -o table
```

| Symptom | Cause | Fix |
|---|---|---|
| Apply fails with `QuotaExceeded` / `OperationNotAllowed ... cores` | The trial's regional vCPU quota (typically 4) can't fit the nodes, or an upgrade's surge node. | `az vm list-usage -l germanywestcentral -o table`. Use `aks_node_count = 1`, or request a quota increase. |
| `RequestDisallowedByPolicy` on `nic-pe-acr...` | The tag policy denied the private endpoint's untagged NIC: the definition update with the private-endpoint exemption hadn't taken effect yet. | Re-run the apply after a few minutes. |
| Cluster create fails, or nodes `NotReady` with image pull errors for `aks-managed-repository/...` | The cache rule is missing or changed, the ACR private endpoint or its DNS records are missing, or the kubelet identity lacks AcrPull. | `az acr cache show -r $ACR -n aks-managed-mcr`; `az network private-dns record-set a list -g $RG -z privatelink.azurecr.io -o table` (expect the registry and `<region>.data` records); `az role assignment list --scope $(az acr show -n $ACR --query id -o tsv) -o table`. |
| `az aks command invoke` fails with `Forbidden` | Your identity lacks *Azure Kubernetes Service RBAC Cluster Admin* on the cluster (local accounts are off). | Add your object ID to `aks_admin_object_ids` (defaults to whoever ran Terraform) and apply. |
| Pods on different nodes can't talk, or DNS times out | The node subnet NSG is missing the pod CIDR rules. Overlay pod-to-pod traffic keeps 10.244.x.x source IPs. | Check `AllowClusterTraffic{In,Out}Bound` on `nsg-hubspoke-aks-dev-nodes`. |
| Workload `ImagePullBackOff` for a Docker Hub image | Expected: there's no egress. | `az acr import --name $ACR --source docker.io/<image>:<tag> --image mirror/<name>:<tag>` and deploy from `$ACR.azurecr.io`. |
| `terraform destroy` leaves `rg-hubspoke-aks-nodes-dev` behind for a while | AKS deletes its node resource group asynchronously. | Wait. If it's still there after ~15 minutes: `az group delete -n rg-hubspoke-aks-nodes-dev`. |
