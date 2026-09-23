# azure/envs/dev

Composes the Azure modules into a hub-and-spoke network: one hub VNet, two
spoke VNets peered to it, an NSG on every subnet, and a Deny policy for
required tags. It's a root module with remote state in the
[azure/bootstrap](../../bootstrap) storage account (blob-lease locking) and a
committed `.terraform.lock.hcl`.

```text
rg-hubspoke-hub-dev          vnet-hubspoke-hub-dev     10.10.0.0/22
                               snet-shared             10.10.1.0/24   (first /24 reserved: firewall, bastion, gateway)
        ▲           ▲
   peering      peering        (not transitive: spoke1 and spoke2 have no route to each other)
        │           │
rg-hubspoke-spoke1-dev       vnet-hubspoke-spoke1-dev  10.11.0.0/22
                               snet-app 10.11.0.0/24 · snet-data 10.11.1.0/24
rg-hubspoke-spoke2-dev       vnet-hubspoke-spoke2-dev  10.12.0.0/22
                               snet-app 10.12.0.0/24 · snet-data 10.12.1.0/24

tag policy (Deny, Indexed) assigned to all three resource groups
```

## What the environment decides

| Concern | Where |
|---|---|
| Names | CAF-style prefixes (`rg-`, `vnet-`, `snet-`, `nsg-`, `peer-`) + `<project>-<vnet>-<env>` |
| Tags | `local.tags` (Project, Environment, Owner, ManagedBy=Terraform) passed to every resource, since azurerm has no `default_tags`. The tag policy enforces the *same* list: `required_tags = keys(local.tags)`. |
| Address plan | Hub: first /24 reserved for platform subnets, second /24 shared services. Spokes: first quarter app, second quarter data, second half free. None of it overlaps the AWS VPC (10.0.0.0/16), so a site-to-site VPN between the two would need no re-addressing. |
| Overlap check | `var.spokes` validation turns every CIDR into an integer range and rejects overlaps at **plan** time, not when Azure refuses the peering at apply. |
| Allowed traffic | See below. Everything else east-west is denied by the NSG baseline. |
| Spokes | `var.spokes` is a map. A third spoke is one more entry: it gets its own resource group, subnets, NSGs, peering and policy assignment. |

## Traffic matrix

| From → To | Allowed | Enforced by |
|---|---|---|
| spoke → hub `snet-shared` | DNS 53 (TCP/UDP) | hub NSG `AllowDnsFromSpokes` |
| hub `snet-shared` → spoke `snet-app` | HTTPS 443 | spoke NSG `AllowHttpsFromHubShared` |
| spoke `snet-app` → same spoke `snet-data` | Postgres 5432 | spoke NSG `AllowPostgresFromApp` |
| spoke1 ↔ spoke2 | nothing | no route (non-transitive peering) **and** `DenyVnetInBound` |
| any subnet → internet | nothing | private subnets (no default outbound access) **and** `DenyInternetOutBound` |

## Usage

```bash
cd azure/envs/dev
terraform -chdir=../../bootstrap output -raw backend_config > backend.hcl
cp terraform.tfvars.example terraform.tfvars   # subscription_id + owner
terraform init -backend-config=backend.hcl
terraform plan -out=tfplan
terraform apply tfplan                          # a few minutes; nothing here is slow to create
terraform output -raw verify_commands           # checks for peering, NSGs and the policy
```

Offline tests (mocked provider, no credentials needed):

```bash
terraform init -backend=false && terraform test
```

See the [Azure README](../../README.md) for verification and teardown.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | ~> 1.16.0 |
| azurerm | ~> 5.6 |

## Providers

| Name | Version |
| ---- | ------- |
| azurerm | 5.6.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| hub | ../../modules/vnet | n/a |
| peering | ../../modules/vnet-peering | n/a |
| spoke | ../../modules/vnet | n/a |
| tag\_policy | ../../modules/tag-policy | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [azurerm_resource_group.hub](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [azurerm_resource_group.spoke](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| owner | Owner tag value, e.g. your GitHub handle or team. | `string` | n/a | yes |
| subscription\_id | Azure subscription to deploy into. Get it with: az account show --query id -o tsv | `string` | n/a | yes |
| environment | Environment name, used in resource names and the Environment tag. | `string` | `"dev"` | no |
| hub\_address\_space | Hub VNet CIDR. The first /24 is reserved for Azure Firewall, Bastion and gateway subnets; the second holds shared services. | `string` | `"10.10.0.0/22"` | no |
| location | Azure region for every resource. | `string` | `"germanywestcentral"` | no |
| project | Project name, used in resource names and the Project tag. | `string` | `"hubspoke"` | no |
| spokes | Spoke VNets keyed by name. Adding a spoke is one entry here: it gets its own resource group, app/data subnets, NSGs, hub peering and tag policy assignment. | <pre>map(object({<br/>    address_space = string<br/>  }))</pre> | <pre>{<br/>  "spoke1": {<br/>    "address_space": "10.11.0.0/22"<br/>  },<br/>  "spoke2": {<br/>    "address_space": "10.12.0.0/22"<br/>  }<br/>}</pre> | no |
| tag\_policy\_effect | Effect of the required-tags policy: Deny blocks untagged resources, Audit only reports them. | `string` | `"Deny"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| address\_plan | VNet and subnet CIDRs, by VNet and subnet key. |
| hub\_vnet\_id | Hub VNet ID. |
| location | Azure region. |
| network\_security\_group\_ids | NSG IDs by VNet key, then subnet key. |
| peering\_names | Hub and spoke link names per spoke. |
| resource\_group\_names | Resource group per VNet. |
| spoke\_vnet\_ids | Spoke VNet IDs by spoke key. |
| subnet\_ids | Subnet IDs by VNet key, then subnet key. |
| tag\_policy\_assignment\_ids | Required-tags policy assignment IDs by resource group key. |
| tag\_policy\_definition\_id | Custom required-tags policy definition ID. |
| verify\_commands | az commands (bash) that check peering, NSG rules and the tag policy. Only step 5 changes anything: it creates and immediately deletes an empty NSG, which is free. |
<!-- END_TF_DOCS -->
