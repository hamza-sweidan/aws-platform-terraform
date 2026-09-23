# One-time setup for Azure remote state: a storage account and blob container
# that azure/envs/* use as their azurerm backend. Locking uses native blob
# leases, so there's nothing extra to create for it.
#
# Access is Entra ID only: Shared Key (account keys and the SAS tokens signed
# with them) is disabled, and the storage firewall admits only the operator's
# IP. Also creates an optional monthly budget so a forgotten resource can't
# silently burn through the subscription's credit.

data "azurerm_client_config" "current" {}

locals {
  # azurerm has no provider-level default_tags, so every resource passes these
  # explicitly. azure/envs/dev backs this up with a Deny policy.
  tags = {
    Project     = var.project
    Environment = "shared"
    Owner       = var.owner
    ManagedBy   = "Terraform"
  }

  # Storage account names are global, 3-24 lowercase letters and digits, no
  # hyphens. A hash of the subscription ID keeps the name unique and stable
  # across runs without a random_string resource.
  storage_account_name = "sttfstate${substr(sha1(var.subscription_id), 0, 12)}"
}

resource "azurerm_resource_group" "state" {
  name     = "rg-${var.project}-tfstate"
  location = var.location
  tags     = local.tags
}

resource "azurerm_storage_account" "state" {
  #checkov:skip=CKV2_AZURE_1:Customer managed keys need a Key Vault and a key whose loss makes the state unreadable. Microsoft-managed keys plus infrastructure (double) encryption cover this threat model.
  #checkov:skip=CKV_AZURE_59:The operator's laptop has no private path into Azure. Public access is limited by the IP firewall (default Deny) and Entra-only auth.
  #checkov:skip=CKV2_AZURE_33:A private endpoint needs a VNet plus VPN or ExpressRoute to reach it from the laptop. Same compensating controls as CKV_AZURE_59.
  #checkov:skip=CKV_AZURE_33:Queue service logging: this account has no queues.
  name                = local.storage_account_name
  resource_group_name = azurerm_resource_group.state.name
  location            = azurerm_resource_group.state.location

  account_kind = "StorageV2"
  account_tier = "Standard"
  # Geo-zone-redundant: three copies across zones in the primary region plus
  # an async copy in the paired region (Germany North), so the state
  # survives a zone or regional outage and never leaves Germany. At a few KB
  # of state the premium over LRS is a fraction of a cent.
  account_replication_type = "GZRS"

  # Identity-only access. With Shared Key off, the account keys can't
  # authorise requests, so leaked keys or account SAS tokens are useless.
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  local_user_enabled              = false
  sftp_enabled                    = false

  allow_nested_items_to_be_public  = false
  cross_tenant_replication_enabled = false
  allowed_copy_scope               = "AAD"
  https_traffic_only_enabled       = true
  min_tls_version                  = "TLS1_2"

  # A second AES-256 layer at the infrastructure level. Free, but it can only
  # be set at creation time.
  infrastructure_encryption_enabled = true

  public_network_access = "Enabled"
  network_rules {
    default_action = "Deny"
    ip_rules       = var.allowed_ip_ranges
    bypass         = ["AzureServices"]
  }

  blob_properties {
    # Every state write becomes a new blob version, so a bad apply can be
    # rolled back by promoting the previous version.
    versioning_enabled = true

    delete_retention_policy {
      days = var.soft_delete_retention_days
    }

    container_delete_retention_policy {
      days = var.soft_delete_retention_days
    }
  }

  # User delegation SAS still works with Shared Key off; cap its lifetime.
  sas_policy {
    expiration_period = "0.01:00:00"
    expiration_action = "Log"
  }

  tags = local.tags

  # Deleting the account orphans every resource its state tracks.
  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_container" "state" {
  #checkov:skip=CKV2_AZURE_21:Blob read logging needs diagnostic settings and a Log Analytics workspace (billed per GB). Blob versioning keeps every state revision, and the Activity Log records control-plane changes.
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.state.id
  container_access_type = "private"

  # Deleting the container deletes every environment's state file with it.
  lifecycle {
    prevent_destroy = true
  }
}

# Owner on the subscription is a control-plane role. Reading and writing
# blobs with Entra ID needs a data-plane role on top, scoped here to the one
# container rather than the whole account.
resource "azurerm_role_assignment" "state_blob_contributor" {
  scope                = azurerm_storage_container.state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
  description          = "Terraform state read/write for the principal that ran azure/bootstrap."
}

# Cost guardrail. Consumption budgets are free.
resource "azurerm_consumption_budget_subscription" "monthly" {
  count = var.budget_alert_email == null ? 0 : 1

  name            = "budget-${var.project}-monthly"
  subscription_id = "/subscriptions/${var.subscription_id}"
  amount          = var.monthly_budget_amount
  time_grain      = "Monthly"

  time_period {
    # A monthly budget must start on the first day of the current month.
    # Anchored to the first plan and ignored afterwards (see lifecycle), so
    # the budget isn't recreated every month.
    start_date = formatdate("YYYY-MM-01'T'00:00:00Z", plantimestamp())
  }

  dynamic "notification" {
    for_each = [50, 80, 100]

    content {
      operator       = "GreaterThan"
      threshold      = notification.value
      threshold_type = "Actual"
      contact_emails = [var.budget_alert_email]
    }
  }

  notification {
    operator       = "GreaterThan"
    threshold      = 100
    threshold_type = "Forecasted"
    contact_emails = [var.budget_alert_email]
  }

  lifecycle {
    ignore_changes = [time_period]
  }
}
