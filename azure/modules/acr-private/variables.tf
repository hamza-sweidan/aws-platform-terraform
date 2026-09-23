variable "name" {
  description = "Registry name: globally unique, 5-50 lowercase letters and digits (no hyphens). Becomes <name>.azurecr.io."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{5,50}$", var.name))
    error_message = "name must be 5-50 lowercase letters and digits."
  }
}

variable "resource_group_name" {
  description = "Resource group for the registry, its private endpoint and the private DNS zone."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "private_endpoint_subnet_id" {
  description = "Subnet for the registry's private endpoint (its private IPs for the registry and data endpoints)."
  type        = string
}

variable "virtual_network_id" {
  description = "VNet whose clients resolve <name>.azurecr.io to the private endpoint (privatelink.azurecr.io is linked to it)."
  type        = string
}

variable "aks_bootstrap_cache_rule" {
  description = "Create the aks-managed-mcr cache rule (mcr.microsoft.com/* -> aks-managed-repository/*) a network-isolated AKS cluster bootstraps from."
  type        = bool
  default     = true
}

variable "untagged_retention_days" {
  description = "Days before untagged manifests are purged."
  type        = number
  default     = 7

  validation {
    condition     = var.untagged_retention_days >= 0 && var.untagged_retention_days <= 365
    error_message = "untagged_retention_days must be 0-365."
  }
}

variable "tags" {
  description = "Tags for every taggable resource. azurerm has no provider default_tags."
  type        = map(string)
  default     = {}
}
