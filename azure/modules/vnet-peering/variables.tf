variable "hub" {
  description = "Hub VNet: the vnet module's id, name, resource_group_name and address_space outputs."
  type = object({
    id                  = string
    name                = string
    resource_group_name = string
    address_space       = list(string)
  })
}

variable "spoke" {
  description = "Spoke VNet: the vnet module's id, name, resource_group_name and address_space outputs."
  type = object({
    id                  = string
    name                = string
    resource_group_name = string
    address_space       = list(string)
  })
}

variable "allow_forwarded_traffic" {
  description = "Let the spoke accept traffic that a firewall or NVA in the hub forwards from elsewhere (e.g. from another spoke). Needed once spoke-to-spoke traffic is routed through a hub firewall."
  type        = bool
  default     = false
}

variable "use_hub_gateway" {
  description = "Route the spoke's on-premises traffic through a VPN/ExpressRoute gateway in the hub (hub: allow_gateway_transit, spoke: use_remote_gateways). The hub must already have a gateway."
  type        = bool
  default     = false
}
