# azure/bootstrap

Creates the storage account that holds Terraform state for every Azure
environment. Run it once per subscription. Like the AWS
[bootstrap](../../bootstrap), it is the only Azure configuration with local
state, because it creates the backend everything else uses.

## What it creates

| Resource | Why |
|---|---|
| Resource group `rg-<project>-tfstate` | Keeps the state account's lifecycle separate from the networks it describes. |
| Storage account `sttfstate<hash>` | Remote state. Names are global and can't contain hyphens; a hash of the subscription ID keeps the name unique and repeatable with no random suffix. |
| GZRS replication | Zone-redundant in Germany West Central, with an async copy to Germany North. Survives a zone or regional outage and stays in Germany. |
| `shared_access_key_enabled = false` | No account keys and no account SAS. Every request is authorised with Entra ID and shows up with the caller's identity. |
| Storage firewall, default `Deny` | Only allowlisted IPs can reach the blob endpoint. Terraform enforces the `Deny` and seeds the list from `allowed_ip_ranges`, then ignores the list: [`scripts/azure-state-firewall.sh`](../../scripts/azure-state-firewall.sh) manages it as your IP changes. |
| Blob versioning + 30-day soft delete | Every state write is a new version. A bad apply can be rolled back, and a deleted blob or container can be restored. |
| Infrastructure encryption | A second AES-256 layer at rest. Free, but it can only be set at creation. |
| Role assignment: Storage Blob Data Contributor | Owner is a control-plane role and can't read blobs through Entra ID. This data-plane role is scoped to the one container. |
| `prevent_destroy` on the account and container | `terraform destroy` fails instead of orphaning every environment's state. |
| Consumption budget (optional) | Emails at 50/80/100% actual and 100% forecast spend. Budgets are free. |

Locking uses **native blob leases**. `terraform plan` and `apply` take a lease
on the state blob and release it at the end, so no second resource is needed.
See [ADR 0008](../../docs/decisions/0008-azure-state-entra-id-only.md).

Cost: storage for a few KB of state plus a few thousand transactions a month,
well under $0.10/month.

## Usage

```bash
az login
cd azure/bootstrap
cp terraform.tfvars.example terraform.tfvars   # subscription, owner, your IP, budget email
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# Hand the account name to the environment without committing it
terraform output -raw backend_config > ../envs/dev/backend.hcl
```

The role assignment can take a few minutes to reach the storage data plane.
If the first `terraform init` in `azure/envs/dev` fails with a 403, see the
[Azure runbook](../../docs/runbook-azure.md#1-terraform-init-fails-with-403-on-the-state-account).

## Working from a new network

Your public IP changes between home, office and mobile. The storage firewall
only guards the blob **data plane**. Changing the firewall is a **control
plane** (ARM) call, which works from anywhere for an Owner or Contributor. So
from a new network:

```bash
scripts/azure-state-firewall.sh status    # allowed IPs, and whether yours is one
scripts/azure-state-firewall.sh allow     # add your current IP
scripts/azure-state-firewall.sh reset     # or: allow only your current IP, drop the rest
```

Terraform keeps `default_action = "Deny"` and would revert anyone opening the
firewall, but `ignore_changes` on `ip_rules` stops it removing the IPs the
script added. The posture lives in code, and the allowlist is day-to-day state.

Keep `azure/bootstrap/terraform.tfstate` safe; it's gitignored. If it's lost,
re-adopt the resources with `terraform import`. The script also reads the
account name from it (or from `STATE_ACCOUNT` / `STATE_RESOURCE_GROUP`).

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | ~> 1.16.0 |
| azurerm | ~> 5.6 |

## Providers

| Name | Version |
| ---- | ------- |
| azurerm | ~> 5.6 |

## Resources

| Name | Type |
| ---- | ---- |
| [azurerm_consumption_budget_subscription.monthly](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/consumption_budget_subscription) | resource |
| [azurerm_resource_group.state](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [azurerm_role_assignment.state_blob_contributor](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_storage_account.state](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_account) | resource |
| [azurerm_storage_container.state](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_container) | resource |
| [azurerm_client_config.current](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/client_config) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| allowed\_ip\_ranges | Public IPv4 addresses or CIDRs allowed through the storage firewall when the account is created. Afterwards Terraform ignores the list; manage it with scripts/azure-state-firewall.sh. Single IPs without a prefix; Azure rejects /31 and /32. Find yours with: curl -s https://api.ipify.org | `list(string)` | n/a | yes |
| owner | Value for the Owner tag, e.g. your GitHub handle. | `string` | n/a | yes |
| subscription\_id | Azure subscription that holds the state account. Get it with: az account show --query id -o tsv | `string` | n/a | yes |
| budget\_alert\_email | Email address for budget alerts. Leave null to skip creating the budget. | `string` | `null` | no |
| location | Azure region for the state account. Use the same region as the environments. | `string` | `"germanywestcentral"` | no |
| monthly\_budget\_amount | Monthly subscription budget, in the subscription's billing currency. Alerts fire at 50/80/100% actual and 100% forecast. | `number` | `20` | no |
| project | Short project name. Used in the resource group name and the Project tag. | `string` | `"hubspoke"` | no |
| soft\_delete\_retention\_days | Days a deleted state blob, blob version or container can still be restored. | `number` | `30` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| backend\_config | Partial backend config for azure/envs/*. Write it with: terraform output -raw backend\_config > ../envs/dev/backend.hcl |
| budget\_name | Name of the monthly budget, or null if no alert email was given. |
| container\_name | Blob container that holds the state files. |
| resource\_group\_name | Resource group that holds the state account. |
| storage\_account\_id | Resource ID of the state account, for role assignments that grant state access. |
| storage\_account\_name | Name of the storage account that stores Terraform state. |
<!-- END_TF_DOCS -->
