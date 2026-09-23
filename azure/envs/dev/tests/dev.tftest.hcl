# Offline plan of the whole environment with a mocked azurerm provider: no
# credentials and no backend (terraform init -backend=false && terraform test).

mock_provider "azurerm" {}

variables {
  subscription_id = "00000000-0000-0000-0000-000000000000"
  owner           = "test-owner"
}

run "hub_two_spokes_and_policy" {
  command = plan

  assert {
    condition     = length(module.spoke) == 2 && length(module.peering) == 2
    error_message = "Expected two spokes, each peered to the hub."
  }

  assert {
    condition = (
      output.address_plan.hub.shared == "10.10.1.0/24" &&
      output.address_plan.spoke1.app == "10.11.0.0/24" &&
      output.address_plan.spoke1.data == "10.11.1.0/24" &&
      output.address_plan.spoke2.app == "10.12.0.0/24"
    )
    error_message = "Address plan doesn't match the documented layout."
  }

  assert {
    condition = alltrue([
      for rg in concat([azurerm_resource_group.hub], values(azurerm_resource_group.spoke)) :
      rg.tags == tomap({ Project = "hubspoke", Environment = "dev", Owner = "test-owner", ManagedBy = "Terraform" })
    ])
    error_message = "Every resource group must carry the four platform tags."
  }

  assert {
    condition     = toset(module.tag_policy.required_tags) == toset(["Project", "Environment", "Owner", "ManagedBy"])
    error_message = "The policy must enforce exactly the tags Terraform applies."
  }

  assert {
    condition     = toset(keys(module.tag_policy.assignment_ids)) == toset(["hub", "spoke1", "spoke2"])
    error_message = "Every platform resource group needs a tag policy assignment."
  }
}

run "rejects_overlapping_spokes" {
  command = plan

  variables {
    spokes = {
      spoke1 = { address_space = "10.11.0.0/22" }
      spoke2 = { address_space = "10.11.2.0/24" }
    }
  }

  expect_failures = [var.spokes]
}

run "rejects_spoke_overlapping_hub" {
  command = plan

  variables {
    spokes = {
      spoke1 = { address_space = "10.10.0.0/24" }
    }
  }

  expect_failures = [var.spokes]
}

run "accepts_adjacent_ranges" {
  command = plan

  variables {
    hub_address_space = "10.10.0.0/22"
    spokes = {
      spoke1 = { address_space = "10.10.4.0/22" }
      spoke2 = { address_space = "10.10.8.0/24" }
    }
  }

  assert {
    condition     = output.address_plan.spoke1.app == "10.10.4.0/24"
    error_message = "Adjacent, non-overlapping ranges must be accepted."
  }
}
