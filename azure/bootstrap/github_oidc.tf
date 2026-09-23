# Read-only identity for `terraform plan` on pull requests
# (.github/workflows/terraform-plan.yml), plus guardrails on the state account.
#
# A user-assigned managed identity with a federated credential, not an Entra
# app registration: it lives in the subscription next to the state, needs no
# directory (Entra) permissions to create, and GitHub's OIDC token is
# exchanged for a short-lived Azure token, so no secret is ever stored.
# Off until var.github_repository is set.

locals {
  github_oidc_enabled = var.github_repository != null
}

resource "azurerm_user_assigned_identity" "github_plan" {
  count = local.github_oidc_enabled ? 1 : 0

  name                = "id-${var.project}-github-plan"
  resource_group_name = azurerm_resource_group.state.name
  location            = azurerm_resource_group.state.location
  tags                = local.tags
}

# Only pull_request runs of this one repository. A push, a manual dispatch or
# another repository presents a different subject and gets no token. GitHub
# doesn't issue OIDC tokens to pull requests from forks.
resource "azurerm_federated_identity_credential" "github_pull_request" {
  count = local.github_oidc_enabled ? 1 : 0

  name                      = "github-pull-request"
  user_assigned_identity_id = azurerm_user_assigned_identity.github_plan[0].id
  issuer                    = "https://token.actions.githubusercontent.com"
  audience                  = ["api://AzureADTokenExchange"]
  subject                   = "repo:${var.github_repository}:pull_request"
}

# Plans refresh every resource in the environments, so the identity reads the
# whole subscription. Reader has no data actions: it can't read blobs, keys
# or secrets.
resource "azurerm_role_assignment" "github_plan_reader" {
  count = local.github_oidc_enabled ? 1 : 0

  scope                = "/subscriptions/${var.subscription_id}"
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.github_plan[0].principal_id
  principal_type       = "ServicePrincipal"
  description          = "terraform plan from GitHub pull requests"
}

# Read, not write: plans run with -lock=false, so CI never takes a lease or
# writes state.
resource "azurerm_role_assignment" "github_plan_state_reader" {
  count = local.github_oidc_enabled ? 1 : 0

  scope                = azurerm_storage_container.state.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.github_plan[0].principal_id
  principal_type       = "ServicePrincipal"
  description          = "Read Terraform state for pull request plans"
}

# GitHub-hosted runners come from a huge, changing IP pool, so the job adds
# its own IP to the storage firewall for the run and removes it afterwards
# (scripts/azure-state-firewall.sh). ARM has no narrower action for network
# rules than storageAccounts/write, so this role is scoped to the one account,
# and the guardrail policies below stop that write from weakening the account.
resource "azurerm_role_definition" "state_firewall_operator" {
  count = local.github_oidc_enabled ? 1 : 0

  name        = "Terraform state firewall operator (${azurerm_storage_account.state.name})"
  scope       = azurerm_storage_account.state.id
  description = "Add or remove IP rules on the Terraform state account's firewall."

  permissions {
    actions = [
      "Microsoft.Storage/storageAccounts/read",
      "Microsoft.Storage/storageAccounts/write",
    ]
  }

  assignable_scopes = [azurerm_storage_account.state.id]
}

resource "azurerm_role_assignment" "github_plan_state_firewall" {
  count = local.github_oidc_enabled ? 1 : 0

  scope              = azurerm_storage_account.state.id
  role_definition_id = azurerm_role_definition.state_firewall_operator[0].role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.github_plan[0].principal_id
  principal_type     = "ServicePrincipal"
  description        = "Open the state firewall for the runner's IP during a plan"
}

# ---------------------------------------------------------------------------
# Guardrails: RBAC grants a coarse "write"; policy limits what a write may do.
# Built-in definitions, assigned to the state resource group only. Whoever
# writes to the account (CI, the firewall script, the portal) can add IP
# rules but can't turn Shared Key back on or open the firewall to everyone.
# ---------------------------------------------------------------------------

locals {
  state_guardrails = {
    deny-state-shared-key = {
      definition = "8c6a50c6-9ffd-4ae7-986f-5fa6111f9a54" # Storage accounts should prevent shared key access
      message    = "The Terraform state account must keep Shared Key disabled (Entra ID only)."
    }
    deny-state-open-network = {
      definition = "34c877ad-507e-4c82-993e-3452a6e0ad3c" # Storage accounts should restrict network access
      message    = "The Terraform state account's firewall must stay default-Deny."
    }
  }
}

resource "azurerm_resource_group_policy_assignment" "state_guardrails" {
  for_each = local.state_guardrails

  name                 = each.key
  resource_group_id    = azurerm_resource_group.state.id
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/${each.value.definition}"

  parameters = jsonencode({
    effect = { value = var.state_guardrail_effect }
  })

  non_compliance_message {
    content = each.value.message
  }
}
