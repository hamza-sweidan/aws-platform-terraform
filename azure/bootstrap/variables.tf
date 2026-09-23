variable "subscription_id" {
  description = "Azure subscription that holds the state account. Get it with: az account show --query id -o tsv"
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a subscription GUID."
  }
}

variable "location" {
  description = "Azure region for the state account. Use the same region as the environments."
  type        = string
  default     = "germanywestcentral"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]+$", var.location))
    error_message = "location must be an Azure region name such as germanywestcentral (lowercase, no spaces)."
  }
}

variable "project" {
  description = "Short project name. Used in the resource group name and the Project tag."
  type        = string
  default     = "hubspoke"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.project))
    error_message = "project must be 3-21 chars of lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "owner" {
  description = "Value for the Owner tag, e.g. your GitHub handle."
  type        = string

  validation {
    condition     = length(trimspace(var.owner)) > 0
    error_message = "owner must not be empty."
  }
}

variable "allowed_ip_ranges" {
  description = "Public IPv4 addresses or CIDRs allowed through the storage firewall (your laptop). Single IPs without a prefix; Azure rejects /31 and /32. Find yours with: curl -s https://api.ipify.org"
  type        = list(string)

  validation {
    condition     = length(var.allowed_ip_ranges) > 0
    error_message = "Allow at least one IP, or nobody can reach the state (the firewall default is Deny)."
  }

  validation {
    condition = alltrue([
      for ip in var.allowed_ip_ranges :
      can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|30))?$", ip))
    ])
    error_message = "Each entry must be an IPv4 address (1.2.3.4) or a CIDR up to /30 (1.2.3.0/24)."
  }
}

variable "soft_delete_retention_days" {
  description = "Days a deleted state blob, blob version or container can still be restored."
  type        = number
  default     = 30

  validation {
    condition     = var.soft_delete_retention_days >= 7 && var.soft_delete_retention_days <= 365
    error_message = "soft_delete_retention_days must be between 7 and 365."
  }
}

variable "monthly_budget_amount" {
  description = "Monthly subscription budget, in the subscription's billing currency. Alerts fire at 50/80/100% actual and 100% forecast."
  type        = number
  default     = 20

  validation {
    condition     = var.monthly_budget_amount > 0
    error_message = "monthly_budget_amount must be positive."
  }
}

variable "budget_alert_email" {
  description = "Email address for budget alerts. Leave null to skip creating the budget."
  type        = string
  default     = null

  validation {
    condition     = var.budget_alert_email == null || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.budget_alert_email))
    error_message = "budget_alert_email must be a valid email address or null."
  }
}
