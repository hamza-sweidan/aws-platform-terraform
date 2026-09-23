variable "name" {
  description = "Policy definition name (unique in the subscription), e.g. require-tags-hubspoke."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,62}$", var.name))
    error_message = "name must be 3-63 lowercase letters, digits and hyphens."
  }
}

variable "required_tags" {
  description = "Tag names every taggable resource must carry with a non-empty value."
  type        = list(string)

  validation {
    # A policy "value count" loop is capped at 100 iterations.
    condition     = length(var.required_tags) > 0 && length(var.required_tags) <= 100
    error_message = "required_tags must list between 1 and 100 tag names."
  }

  validation {
    condition     = length(distinct(var.required_tags)) == length(var.required_tags)
    error_message = "required_tags must not contain duplicates."
  }
}

variable "effect" {
  description = "Deny blocks non-compliant creates and updates; Audit only reports them; Disabled turns the check off."
  type        = string
  default     = "Deny"

  validation {
    condition     = contains(["Deny", "Audit", "Disabled"], var.effect)
    error_message = "effect must be Deny, Audit or Disabled."
  }
}

variable "resource_group_ids" {
  description = "Resource groups to assign the policy to, keyed by a short static name (hub, spoke1, ...)."
  type        = map(string)

  validation {
    condition     = length(var.resource_group_ids) > 0
    error_message = "Assign the policy to at least one resource group."
  }
}
