variable "subscription_id" {
  description = "Azure subscription to deploy into. Get it with: az account show --query id -o tsv"
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a subscription GUID."
  }
}

variable "location" {
  description = "Azure region for every resource."
  type        = string
  default     = "germanywestcentral"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]+$", var.location))
    error_message = "location must be an Azure region name such as germanywestcentral (lowercase, no spaces)."
  }
}

variable "project" {
  description = "Project name, used in resource names and the Project tag."
  type        = string
  default     = "hubspoke"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.project))
    error_message = "project must be 3-21 chars of lowercase letters, digits and hyphens."
  }
}

variable "environment" {
  description = "Environment name, used in resource names and the Environment tag."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "owner" {
  description = "Owner tag value, e.g. your GitHub handle or team."
  type        = string

  validation {
    condition     = length(trimspace(var.owner)) > 0
    error_message = "owner must not be empty."
  }
}

variable "hub_address_space" {
  description = "Hub VNet CIDR. The first /24 is reserved for Azure Firewall, Bastion and gateway subnets; the second holds shared services."
  type        = string
  default     = "10.10.0.0/22"

  validation {
    condition     = can(cidrhost(var.hub_address_space, 0)) && tonumber(split("/", var.hub_address_space)[1]) <= 22
    error_message = "hub_address_space must be a valid IPv4 CIDR of /22 or larger."
  }
}

variable "spokes" {
  description = "Spoke VNets keyed by name. Adding a spoke is one entry here: it gets its own resource group, app/data subnets, NSGs, hub peering and tag policy assignment."
  type = map(object({
    address_space = string
  }))
  default = {
    spoke1 = { address_space = "10.11.0.0/22" }
    spoke2 = { address_space = "10.12.0.0/22" }
  }

  validation {
    condition     = length(var.spokes) > 0 && alltrue([for k in keys(var.spokes) : can(regex("^[a-z][a-z0-9]{1,14}$", k))])
    error_message = "Define at least one spoke; keys must be 2-15 lowercase letters and digits."
  }

  validation {
    condition = alltrue([
      for s in values(var.spokes) :
      can(cidrhost(s.address_space, 0)) && tonumber(split("/", s.address_space)[1]) <= 24
    ])
    error_message = "Each spoke address_space must be a valid IPv4 CIDR of /24 or larger (it is split into four subnets)."
  }

  validation {
    # Peered VNets must not overlap, or Azure rejects the peering at apply
    # time. Each CIDR is turned into an integer range [start, start + size)
    # and every pair (hub included) must be disjoint, so it fails at plan.
    condition = alltrue(flatten([
      for i, a in [
        for c in concat([var.hub_address_space], [for s in values(var.spokes) : s.address_space]) : {
          start = sum([for n, octet in split(".", cidrhost(c, 0)) : tonumber(octet) * pow(256, 3 - n)])
          size  = pow(2, 32 - tonumber(split("/", c)[1]))
        }
        ] : [
        for j, b in [
          for c in concat([var.hub_address_space], [for s in values(var.spokes) : s.address_space]) : {
            start = sum([for n, octet in split(".", cidrhost(c, 0)) : tonumber(octet) * pow(256, 3 - n)])
            size  = pow(2, 32 - tonumber(split("/", c)[1]))
          }
        ] : a.start + a.size <= b.start || b.start + b.size <= a.start if i < j
      ]
    ]))
    error_message = "The hub and spoke address spaces must not overlap each other."
  }
}

variable "tag_policy_effect" {
  description = "Effect of the required-tags policy: Deny blocks untagged resources, Audit only reports them."
  type        = string
  default     = "Deny"

  validation {
    condition     = contains(["Deny", "Audit", "Disabled"], var.tag_policy_effect)
    error_message = "tag_policy_effect must be Deny, Audit or Disabled."
  }
}
