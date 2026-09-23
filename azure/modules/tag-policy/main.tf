# Enforces required tags with Azure Policy. azurerm has no provider-level
# default_tags, so every resource must pass its tags explicitly; this policy
# is the backstop that makes a forgotten one fail the apply instead of
# quietly landing untagged.
#
# - One custom definition, created at subscription scope and parameterised
#   by the tag list and the effect, so it's reusable across assignments.
# - mode = "Indexed": only resource types that support tags and a location
#   are evaluated. In "All" mode child resources such as subnets and
#   peerings, which can't carry tags at all, would be denied too.
# - Assigned per resource group, not per subscription (see README).

resource "azurerm_policy_definition" "require_tags" {
  name         = var.name
  policy_type  = "Custom"
  mode         = "Indexed"
  display_name = "Require a set of tags on resources"
  description  = "Denies (or audits) any taggable resource that is missing one of the listed tags or has it set to an empty value."

  metadata = jsonencode({
    category = "Tags"
    version  = "1.0.0"
  })

  parameters = jsonencode({
    tagNames = {
      type = "Array"
      metadata = {
        displayName = "Required tag names"
        description = "Every name in this list must be present with a non-empty value."
      }
    }
    effect = {
      type          = "String"
      allowedValues = ["Deny", "Audit", "Disabled"]
      defaultValue  = "Deny"
      metadata = {
        displayName = "Effect"
        description = "Deny blocks the request; Audit only records non-compliance."
      }
    }
  })

  # "value count" loops over the tagNames parameter and counts the tags that
  # are missing or empty on the request. Any count above zero triggers the
  # effect, so one definition covers any number of required tags.
  # The keys are quoted because checkov's HCL parser reads a bare `if` as a
  # keyword and would skip the whole file.
  policy_rule = jsonencode({
    "if" = {
      allOf = [
        {
          count = {
            value = "[parameters('tagNames')]"
            name  = "tagName"
            where = {
              anyOf = [
                {
                  field  = "[concat('tags[', current('tagName'), ']')]"
                  exists = "false"
                },
                {
                  field  = "[concat('tags[', current('tagName'), ']')]"
                  equals = ""
                },
              ]
            }
          }
          greater = 0
        },
        # A private endpoint's network interface is created by the Network
        # resource provider, untagged, and the caller can't tag it. Without
        # this exemption the Deny would block every private endpoint.
        {
          not = {
            allOf = [
              {
                field  = "type"
                equals = "Microsoft.Network/networkInterfaces"
              },
              {
                field  = "Microsoft.Network/networkInterfaces/privateEndpoint"
                exists = "true"
              },
            ]
          }
        },
      ]
    }
    "then" = {
      effect = "[parameters('effect')]"
    }
  })
}

resource "azurerm_resource_group_policy_assignment" "require_tags" {
  for_each = var.resource_group_ids

  name                 = "${var.name}-${each.key}"
  display_name         = "Require tags (${each.key})"
  resource_group_id    = each.value
  policy_definition_id = azurerm_policy_definition.require_tags.id
  enforce              = true

  parameters = jsonencode({
    tagNames = { value = var.required_tags }
    effect   = { value = var.effect }
  })

  # Shown in the RequestDisallowedByPolicy error, so whoever hits it knows
  # what to fix without looking the policy up.
  non_compliance_message {
    content = "Every resource here needs these tags with non-empty values: ${join(", ", var.required_tags)}."
  }
}
