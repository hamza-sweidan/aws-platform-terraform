# tag-policy

Enforces required tags with Azure Policy: one custom policy definition,
assigned to each platform resource group with effect **Deny**. A request that
creates or updates a taggable resource without every listed tag, or with one
set to `""`, fails with `RequestDisallowedByPolicy`.

**Why this matters here:** the azurerm provider has no `default_tags` (unlike
the AWS provider). Every resource has to pass `tags = local.tags` itself, so
one forgotten argument would quietly create an untagged resource. With this
policy the apply fails instead, and a portal click-op gets the same treatment.

## How the rule works

```json
"if": {
  "count": {
    "value": "[parameters('tagNames')]",
    "name": "tagName",
    "where": { "anyOf": [
      { "field": "[concat('tags[', current('tagName'), ']')]", "exists": "false" },
      { "field": "[concat('tags[', current('tagName'), ']')]", "equals": "" }
    ]}
  },
  "greater": 0
},
"then": { "effect": "[parameters('effect')]" }
```

A *value count* loops over the `tagNames` parameter and counts the tags that
are missing or empty in the request. If the count is above zero, the effect
applies. One definition therefore handles any number of tags.

One narrow exemption: **network interfaces that belong to a private
endpoint** (`Microsoft.Network/networkInterfaces/privateEndpoint` exists).
Azure creates that NIC itself, untagged, and there's no way to pass it tags,
so without the exemption the Deny would block every private endpoint. All
other NICs still need the tags.

## Design choices

| Choice | Why |
|---|---|
| **Custom definition, not the built-in** | The built-in *Require a tag on resources* checks a single tag, so 4 tags × 3 resource groups would take 12 assignments. This takes 3. |
| **`mode = "Indexed"`** | Only resource types that support tags and a location are evaluated. In `All` mode, child resources that can't carry tags at all (subnets, peerings) would be denied, and so would every apply. |
| **Resource-group scope** | Limits the blast radius in a personal subscription, and leaves Azure-managed groups alone. For example, Azure auto-creates `NetworkWatcherRG` *without tags* the first time a VNet is created in a region; a subscription-wide Deny would quietly block that. In an enterprise landing zone this would be assigned once at a management group. |
| **Deny, not Modify** | `Modify` (inherit tags from the resource group) needs a managed identity with Contributor rights to remediate. It also hides the mistake instead of surfacing it. Deny makes Terraform fail at the offending resource. |
| **Effect is a parameter** | Switch to `Audit` to see what *would* be denied without blocking anything. That's the safe way to roll a Deny policy into an existing estate. |
| **Empty values rejected** | `Owner = ""` passes an `exists` check. The second condition closes that gap. |
| **Custom non-compliance message** | Shown in the error itself, so whoever hits it sees which tags are needed without looking up the policy. |

## Limits and gotchas

- **Resource groups themselves aren't checked.** An assignment at RG scope
  evaluates what's *inside* the group. The groups get their tags from
  Terraform.
- **New assignments take time to take effect** (typically minutes, up to
  about 30). A resource created in the same apply as the assignment might
  not be evaluated yet. Verify afterwards; see the Azure README.
- **Deny doesn't touch existing resources.** Anything created before the
  assignment is only *reported* as non-compliant.

## Tests

`tests/tag_policy.tftest.hcl` runs with a mocked provider. It checks the
`Indexed` mode, that the rule loops over the parameter and takes its effect
from the assignment, one assignment per resource group, and that bad input is
rejected.

## Usage

```hcl
module "tag_policy" {
  source = "../../modules/tag-policy"

  name          = "require-tags-hubspoke"
  required_tags = ["Project", "Environment", "Owner", "ManagedBy"]
  resource_group_ids = {
    hub    = azurerm_resource_group.hub.id
    spoke1 = azurerm_resource_group.spoke["spoke1"].id
  }
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
| [azurerm_policy_definition.require_tags](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/policy_definition) | resource |
| [azurerm_resource_group_policy_assignment.require_tags](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group_policy_assignment) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| name | Policy definition name (unique in the subscription), e.g. require-tags-hubspoke. | `string` | n/a | yes |
| required\_tags | Tag names every taggable resource must carry with a non-empty value. | `list(string)` | n/a | yes |
| resource\_group\_ids | Resource groups to assign the policy to, keyed by a short static name (hub, spoke1, ...). | `map(string)` | n/a | yes |
| effect | Deny blocks non-compliant creates and updates; Audit only reports them; Disabled turns the check off. | `string` | `"Deny"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| assignment\_ids | Policy assignment IDs by resource group key. |
| policy\_definition\_id | ID of the custom required-tags policy definition. |
| required\_tags | The tag names being enforced. |
<!-- END_TF_DOCS -->
