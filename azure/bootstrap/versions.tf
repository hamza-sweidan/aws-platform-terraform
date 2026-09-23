terraform {
  # Root modules pin to a patch series, same as the AWS side.
  required_version = "~> 1.16.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.6"
    }
  }

  # No backend block on purpose: this configuration creates the storage
  # account, so its own state has to start life locally (chicken-and-egg).
}

provider "azurerm" {
  # Pinned so a plan can never land in whichever subscription `az account set`
  # selected last. The Azure counterpart of the AWS provider's allowed_account_ids.
  subscription_id = var.subscription_id

  # azurerm 5.0 stopped registering ~60 Resource Providers on startup. Register
  # only the ones this configuration creates resources in.
  resource_providers_to_register = ["Microsoft.Storage", "Microsoft.Consumption"]

  # Shared Key is disabled on the state account, so any data-plane call the
  # provider makes has to authenticate with Entra ID instead.
  storage_use_azuread = true

  features {}
}
