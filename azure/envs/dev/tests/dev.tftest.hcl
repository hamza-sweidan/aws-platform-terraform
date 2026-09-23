# Offline plan of the whole environment with a mocked azurerm provider: no
# credentials and no backend (terraform init -backend=false && terraform test).

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      object_id = "00000000-0000-0000-0000-00000000aaaa"
      tenant_id = "00000000-0000-0000-0000-00000000bbbb"
    }
  }
}

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

run "aks_is_off_by_default" {
  command = plan

  assert {
    condition = (
      length(module.aks) == 0 && length(module.acr) == 0 && length(azurerm_resource_group.aks) == 0 &&
      output.aks_cluster_name == null
    )
    error_message = "Nothing billable from Phase 3 unless enable_aks = true."
  }
}

run "aks_on_adds_spoke_registry_and_cluster" {
  command = plan

  variables {
    enable_aks = true
  }

  assert {
    condition = (
      length(module.aks) == 1 && length(module.acr) == 1 && length(module.aks_peering) == 1 &&
      module.aks_spoke[0].subnet_address_prefixes["nodes"] == "10.13.0.0/24"
    )
    error_message = "enable_aks must add the AKS spoke (nodes /24), its peering, the registry and the cluster."
  }

  assert {
    condition     = contains(keys(module.tag_policy.assignment_ids), "aks")
    error_message = "The AKS resource group must be covered by the tag policy too."
  }

  assert {
    condition     = output.aks_cluster_name == "aks-hubspoke-dev" && startswith(output.acr_name, "acrhubspoke")
    error_message = "Names come from <project>-<environment>; registry names are hyphen-free."
  }
}

run "rejects_aks_space_overlapping_a_spoke" {
  command = plan

  variables {
    aks_address_space = "10.11.2.0/24"
  }

  expect_failures = [var.aks_address_space]
}

run "rejects_three_aks_nodes" {
  command = plan

  variables {
    aks_node_count = 3
  }

  expect_failures = [var.aks_node_count]
}
