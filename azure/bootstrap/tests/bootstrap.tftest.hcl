# Offline unit tests with a mocked azurerm provider (no credentials needed).

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      object_id = "00000000-0000-0000-0000-00000000aaaa"
      tenant_id = "00000000-0000-0000-0000-00000000bbbb"
    }
  }

  # The provider validates ARM ID formats, so mocked IDs must look real.
  mock_resource "azurerm_resource_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hubspoke-tfstate" }
  }
  mock_resource "azurerm_storage_account" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hubspoke-tfstate/providers/Microsoft.Storage/storageAccounts/sttfstatetest" }
  }
  mock_resource "azurerm_storage_container" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hubspoke-tfstate/providers/Microsoft.Storage/storageAccounts/sttfstatetest/blobServices/default/containers/tfstate" }
  }
  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hubspoke-tfstate/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hubspoke-github-plan"
      principal_id = "00000000-0000-0000-0000-00000000cccc"
      client_id    = "00000000-0000-0000-0000-00000000dddd"
    }
  }
  mock_resource "azurerm_role_definition" {
    defaults = { role_definition_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/00000000-0000-0000-0000-00000000eeee" }
  }
}

variables {
  subscription_id   = "00000000-0000-0000-0000-000000000000"
  owner             = "test-owner"
  allowed_ip_ranges = ["203.0.113.10"]
}

run "state_account_is_entra_only_and_firewalled" {
  command = plan

  assert {
    condition = (
      azurerm_storage_account.state.shared_access_key_enabled == false &&
      azurerm_storage_account.state.network_rules[0].default_action == "Deny" &&
      azurerm_storage_account.state.min_tls_version == "TLS1_2"
    )
    error_message = "Shared Key off, firewall default-Deny, TLS 1.2."
  }

  assert {
    condition     = azurerm_role_assignment.state_blob_contributor.role_definition_name == "Storage Blob Data Contributor"
    error_message = "The operator needs a data-plane role on the container."
  }
}

run "guardrails_deny_weakening_the_account" {
  command = plan

  variables {
    state_guardrail_effect = "Deny"
  }

  assert {
    condition = alltrue([
      for a in azurerm_resource_group_policy_assignment.state_guardrails :
      jsondecode(a.parameters).effect.value == "Deny"
    ]) && length(azurerm_resource_group_policy_assignment.state_guardrails) == 2
    error_message = "Both guardrails (shared key, network) must be assigned with Deny."
  }
}

run "no_ci_identity_by_default" {
  command = plan

  # Explicit, because a local terraform.tfvars (gitignored) may set it.
  variables {
    github_repository = null
  }

  assert {
    condition     = length(azurerm_user_assigned_identity.github_plan) == 0 && length(azurerm_federated_identity_credential.github_pull_request) == 0
    error_message = "No CI identity unless github_repository is set."
  }
}

run "ci_identity_trusts_only_this_repos_pull_requests" {
  command = apply

  variables {
    github_repository     = "hamza-sweidan/aws-platform-terraform"
    github_repository_ids = { owner = 210244091, repository = 1383148050 }
  }

  assert {
    condition = (
      azurerm_federated_identity_credential.github_pull_request[0].subject == "repo:hamza-sweidan@210244091/aws-platform-terraform@1383148050:pull_request" &&
      azurerm_federated_identity_credential.github_pull_request[0].issuer == "https://token.actions.githubusercontent.com" &&
      toset(azurerm_federated_identity_credential.github_pull_request[0].audience) == toset(["api://AzureADTokenExchange"])
    )
    error_message = "The federated credential must trust exactly this repository's pull_request tokens."
  }

  assert {
    condition = (
      azurerm_role_assignment.github_plan_reader[0].role_definition_name == "Reader" &&
      azurerm_role_assignment.github_plan_state_reader[0].role_definition_name == "Storage Blob Data Reader" &&
      azurerm_role_assignment.github_plan_state_reader[0].scope == azurerm_storage_container.state.id
    )
    error_message = "CI reads the subscription and the state container; it never writes state."
  }

  assert {
    condition = toset(azurerm_role_definition.state_firewall_operator[0].permissions[0].actions) == toset([
      "Microsoft.Storage/storageAccounts/read",
      "Microsoft.Storage/storageAccounts/write",
    ]) && toset(azurerm_role_definition.state_firewall_operator[0].assignable_scopes) == toset([azurerm_storage_account.state.id])
    error_message = "The firewall role must be limited to the state account."
  }
}

# A name-only subject would also match a repository that later reuses the name.
run "ci_identity_requires_immutable_ids" {
  command = plan

  variables {
    github_repository     = "hamza-sweidan/aws-platform-terraform"
    github_repository_ids = null
  }

  expect_failures = [var.github_repository_ids]
}

run "rejects_unknown_guardrail_effect" {
  command = plan

  variables {
    state_guardrail_effect = "Modify"
  }

  expect_failures = [var.state_guardrail_effect]
}
