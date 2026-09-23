# Offline unit tests with a mocked azurerm provider (no credentials needed).

mock_provider "azurerm" {}

variables {
  name          = "require-tags-test"
  required_tags = ["Project", "Environment", "Owner", "ManagedBy"]
  resource_group_ids = {
    hub    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub"
    spoke1 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-spoke1"
  }
}

run "definition_is_indexed_and_loops_over_the_tag_parameter" {
  command = plan

  assert {
    condition     = azurerm_policy_definition.require_tags.mode == "Indexed"
    error_message = "Mode must be Indexed so untaggable child resources (subnets, peerings) aren't denied."
  }

  assert {
    condition     = jsondecode(azurerm_policy_definition.require_tags.policy_rule)["if"]["allOf"][0]["count"]["value"] == "[parameters('tagNames')]"
    error_message = "The rule must count over the tagNames parameter, not a hard-coded list."
  }

  assert {
    condition     = jsondecode(azurerm_policy_definition.require_tags.policy_rule)["if"]["allOf"][1]["not"]["allOf"][1]["field"] == "Microsoft.Network/networkInterfaces/privateEndpoint"
    error_message = "Only private endpoint NICs (created untagged by Azure) may be exempt."
  }

  assert {
    condition     = jsondecode(azurerm_policy_definition.require_tags.policy_rule)["then"]["effect"] == "[parameters('effect')]"
    error_message = "The effect must come from the assignment parameter."
  }
}

run "one_assignment_per_resource_group" {
  command = plan

  assert {
    condition     = length(azurerm_resource_group_policy_assignment.require_tags) == 2
    error_message = "Expected one assignment per resource group."
  }

  assert {
    condition = alltrue([
      for a in azurerm_resource_group_policy_assignment.require_tags :
      jsondecode(a.parameters).tagNames.value == ["Project", "Environment", "Owner", "ManagedBy"] &&
      jsondecode(a.parameters).effect.value == "Deny" &&
      a.enforce
    ])
    error_message = "Assignments must pass the tag list and default to an enforced Deny."
  }
}

run "audit_mode" {
  command = plan

  variables {
    effect = "Audit"
  }

  assert {
    condition     = alltrue([for a in azurerm_resource_group_policy_assignment.require_tags : jsondecode(a.parameters).effect.value == "Audit"])
    error_message = "effect = Audit must reach the assignment."
  }
}

run "rejects_unknown_effect" {
  command = plan

  variables {
    effect = "Modify"
  }

  expect_failures = [var.effect]
}

run "rejects_empty_tag_list" {
  command = plan

  variables {
    required_tags = []
  }

  expect_failures = [var.required_tags]
}
