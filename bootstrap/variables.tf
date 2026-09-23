variable "region" {
  description = "AWS region for the state bucket. Use the same region as the environments."
  type        = string
  default     = "eu-central-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.region))
    error_message = "region must look like an AWS region code, e.g. eu-central-1."
  }
}

variable "project" {
  description = "Short project name. Used in the bucket name and the Project tag."
  type        = string
  default     = "aws-platform"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.project))
    error_message = "project must be 3-21 chars of lowercase letters, digits and hyphens, starting with a letter (S3 naming rules)."
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

variable "noncurrent_version_retention_days" {
  description = "Days to keep old state versions before S3 deletes them. Old versions are your undo button for a bad apply."
  type        = number
  default     = 90

  validation {
    condition     = var.noncurrent_version_retention_days >= 7
    error_message = "Keep at least 7 days of state history."
  }
}

variable "monthly_budget_usd" {
  description = "Monthly AWS cost budget in USD. Alerts fire at 50/80/100% actual and 100% forecast."
  type        = number
  default     = 120

  validation {
    condition     = var.monthly_budget_usd > 0
    error_message = "monthly_budget_usd must be positive."
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

variable "github_repository" {
  description = "GitHub repository (owner/name) whose pull_request workflows may assume the read-only plan role. Leave null to create no OIDC provider or role."
  type        = string
  default     = null

  validation {
    condition     = var.github_repository == null || can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "github_repository must look like owner/name."
  }
}

variable "github_repository_ids" {
  description = "Immutable IDs of github_repository, which GitHub puts in the OIDC subject (repo:owner@ID/name@ID). Look them up with: gh api repos/OWNER/NAME --jq '{owner: .owner.id, repository: .id}'"
  type = object({
    owner      = number
    repository = number
  })
  default = null

  validation {
    condition     = var.github_repository == null || var.github_repository_ids != null
    error_message = "Set github_repository_ids together with github_repository; the role trust matches GitHub's immutable subject."
  }
}
