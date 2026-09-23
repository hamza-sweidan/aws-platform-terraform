# 0007. Enforce required tags with an Azure Policy Deny at resource-group scope

- **Status:** Accepted
- **Date:** 2026-09-23

## Context

Tags (Project, Environment, Owner, ManagedBy) drive cost reports and
ownership. On AWS the provider's `default_tags` puts them on every resource.
The azurerm provider has **no equivalent**, so every resource has to pass
`tags = local.tags` explicitly. One forgotten argument quietly creates an
untagged resource, and so does every portal click-op.

## Decision

A custom Azure Policy definition (`azure/modules/tag-policy`):

- **Rule:** a *value count* over a `tagNames` parameter counts tags that are
  missing or empty. Any count above zero triggers the effect. One definition
  handles any number of tags.
- **Mode `Indexed`:** only resource types that support tags and a location are
  evaluated. `All` would also deny subnets and peerings, which can't hold tags.
- **Effect `Deny`** by default, as a parameter so it can be switched to
  `Audit`.
- **Assigned to each platform resource group,** not to the subscription.
- **Tag list derived from Terraform:** `required_tags = keys(local.tags)`, so
  the policy and what Terraform applies can't drift apart. An offline test
  checks it.

## Consequences

**Good**
- A missing `tags` argument fails the apply at the offending resource with a
  message naming the required tags, instead of reaching production.
- The same guardrail applies to the portal, CLI and any other tool.
- Free: Azure Policy doesn't charge for evaluating Azure resources.

**Costs and limits**
- Resource groups themselves aren't covered. An RG-scope assignment evaluates
  what's inside the group.
- A new assignment takes a while to take effect (minutes, up to about 30).
  Resources created in the same apply may not be evaluated yet.
- Deny only acts on creates and updates. Existing untagged resources are
  reported as non-compliant, not blocked or fixed.

## Why resource-group scope

At subscription scope the policy would also hit resources this project
doesn't own. The concrete example: the first time a VNet is created in a
region, Azure auto-creates `NetworkWatcherRG` and a Network Watcher, *without
tags*. A subscription-wide Deny that also covered resource groups would block
that silently. In a personal lab subscription, a narrow scope keeps the blast
radius small. In an enterprise landing zone the same definition would be
assigned once at a management group, with `notScopes` for platform-managed
groups.

## Alternatives considered

| Option | Why not |
|---|---|
| Built-in *Require a tag on resources* | Checks a single tag: 4 tags × 3 resource groups = 12 assignments. |
| `Modify` / *Inherit a tag from the resource group* | Needs a managed identity with write access to remediate, and fixes the symptom silently. Deny surfaces the missing argument in code review. |
| `Audit` only | Reports the problem after the resource exists. Kept as a switch, not the default. |
| tflint / checkov tag rules in CI | Catches Terraform only, not portal or CLI changes. Complementary, not a replacement. |
