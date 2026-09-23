variable "name" {
  description = "Base name, e.g. hubspoke-hub-dev. Resources become vnet-<name>, snet-<subnet> and nsg-<name>-<subnet>."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,48}[a-z0-9]$", var.name))
    error_message = "name must be 3-50 lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "resource_group_name" {
  description = "Resource group for the VNet and its NSGs."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "address_space" {
  description = "VNet address space. Must not overlap any VNet it will be peered with."
  type        = list(string)

  validation {
    condition     = length(var.address_space) > 0 && alltrue([for c in var.address_space : can(cidrhost(c, 0))])
    error_message = "address_space must contain at least one valid IPv4 CIDR."
  }
}

variable "subnets" {
  description = <<-EOT
    Subnets keyed by short name (snet-<key>). Every subnet gets its own NSG with
    the module's baseline rules (see README) plus the rules given here. For each
    rule, remote_address_prefixes is the source of an Inbound rule and the
    destination of an Outbound rule. The other side is this subnet, unless
    local_address_prefixes overrides it (e.g. to include an AKS overlay pod
    CIDR, whose addresses live outside the subnet).
  EOT
  type = map(object({
    address_prefix = string
    nsg_rules = optional(map(object({
      priority                = number
      direction               = string
      access                  = optional(string, "Allow")
      protocol                = string
      remote_address_prefixes = list(string)
      local_address_prefixes  = optional(list(string))
      destination_port_ranges = list(string)
      description             = optional(string, "")
    })), {})
  }))

  validation {
    condition     = alltrue([for s in values(var.subnets) : can(cidrhost(s.address_prefix, 0))])
    error_message = "Every subnet address_prefix must be a valid IPv4 CIDR."
  }

  validation {
    condition     = alltrue([for k in keys(var.subnets) : can(regex("^[a-z][a-z0-9-]{0,30}$", k))])
    error_message = "Subnet keys must be lowercase letters, digits and hyphens (they become snet-<key>)."
  }

  validation {
    condition = alltrue(flatten([
      for s in values(var.subnets) : [
        for r in values(s.nsg_rules) : r.priority >= 100 && r.priority <= 3999
      ]
    ]))
    error_message = "NSG rule priorities must be 100-3999. 4000-4096 is reserved for the module's baseline rules."
  }

  validation {
    condition = alltrue(flatten([
      for s in values(var.subnets) : [
        for r in values(s.nsg_rules) :
        contains(["Inbound", "Outbound"], r.direction) &&
        contains(["Allow", "Deny"], r.access) &&
        contains(["Tcp", "Udp", "Icmp", "*"], r.protocol)
      ]
    ]))
    error_message = "direction must be Inbound/Outbound, access Allow/Deny, protocol Tcp/Udp/Icmp/*."
  }

  validation {
    # Azure only accepts a service tag (VirtualNetwork, Internet, ...) in the
    # singular prefix field, so a list must be plain CIDRs.
    condition = alltrue(flatten([
      for s in values(var.subnets) : [
        for r in values(s.nsg_rules) : [
          for prefixes in [r.remote_address_prefixes, coalesce(r.local_address_prefixes, [s.address_prefix])] :
          length(prefixes) == 1 ||
          (length(prefixes) > 1 && alltrue([for p in prefixes : can(cidrhost(p, 0))]))
        ]
      ]
    ]))
    error_message = "remote_address_prefixes and local_address_prefixes must each be one CIDR or service tag, or several CIDRs (service tags can't be mixed into a list)."
  }

  validation {
    condition = alltrue(flatten([
      for s in values(var.subnets) : [
        for d in ["Inbound", "Outbound"] :
        length(distinct([for r in values(s.nsg_rules) : r.priority if r.direction == d])) ==
        length([for r in values(s.nsg_rules) : r.priority if r.direction == d])
      ]
    ]))
    error_message = "NSG rule priorities must be unique per subnet and direction."
  }
}

variable "deny_internet_outbound" {
  description = "Add a DenyInternetOutBound rule to every NSG, overriding Azure's default AllowInternetOutBound."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags for the VNet and NSGs. azurerm has no provider default_tags, so the caller passes them explicitly."
  type        = map(string)
  default     = {}
}
