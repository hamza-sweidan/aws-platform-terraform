# Offline unit tests: the azurerm provider is mocked, so these run in CI with
# no Azure credentials.   terraform init -backend=false && terraform test

mock_provider "azurerm" {}

variables {
  name                = "test-hub"
  resource_group_name = "rg-test"
  location            = "germanywestcentral"
  address_space       = ["10.10.0.0/22"]
  tags                = { Project = "test", Owner = "me" }

  subnets = {
    shared = {
      address_prefix = "10.10.1.0/24"
      nsg_rules = {
        AllowDnsFromSpokes = {
          priority                = 100
          direction               = "Inbound"
          protocol                = "*"
          remote_address_prefixes = ["10.11.0.0/22", "10.12.0.0/22"]
          destination_port_ranges = ["53"]
        }
      }
    }
    tools = {
      address_prefix = "10.10.2.0/24"
    }
  }
}

run "baseline_rules_on_every_subnet" {
  command = plan

  assert {
    condition = alltrue([
      for nsg in azurerm_network_security_group.this : anytrue([
        for r in nsg.security_rule :
        r.name == "DenyVnetInBound" && r.priority == 4096 && r.access == "Deny" && r.source_address_prefix == "VirtualNetwork"
      ])
    ])
    error_message = "Every NSG must deny VirtualNetwork inbound at 4096 to override AllowVnetInBound."
  }

  assert {
    condition = alltrue([
      for nsg in azurerm_network_security_group.this : anytrue([
        for r in nsg.security_rule :
        r.name == "DenyInternetOutBound" && r.direction == "Outbound" && r.destination_address_prefix == "Internet"
      ])
    ])
    error_message = "Every NSG must deny Internet outbound by default."
  }

  assert {
    condition = anytrue([
      for r in azurerm_network_security_group.this["tools"].security_rule :
      r.name == "AllowSameSubnetInBound" && r.source_address_prefix == "10.10.2.0/24" && r.destination_address_prefix == "10.10.2.0/24"
    ])
    error_message = "AllowSameSubnetInBound must be scoped to the subnet's own CIDR."
  }

  assert {
    condition     = alltrue([for s in azurerm_subnet.this : s.default_outbound_access_enabled == false])
    error_message = "Subnets must be private (no default outbound access)."
  }

  assert {
    # The tag policy denies untagged resources, so a missing tags argument
    # would fail the apply.
    condition = (
      azurerm_virtual_network.this.tags == tomap({ Project = "test", Owner = "me" }) &&
      alltrue([for nsg in azurerm_network_security_group.this : nsg.tags == tomap({ Project = "test", Owner = "me" })])
    )
    error_message = "The VNet and every NSG must carry the caller's tags."
  }
}

run "caller_rules_map_to_the_right_fields" {
  command = plan

  assert {
    condition = anytrue([
      for r in azurerm_network_security_group.this["shared"].security_rule :
      r.name == "AllowDnsFromSpokes" &&
      toset(r.source_address_prefixes) == toset(["10.11.0.0/22", "10.12.0.0/22"]) &&
      r.destination_address_prefix == "10.10.1.0/24" &&
      r.destination_port_range == "53"
    ])
    error_message = "An inbound rule must use the remote prefixes as source and the subnet as destination."
  }
}

run "local_side_can_include_a_pod_cidr" {
  command = plan

  variables {
    subnets = {
      nodes = {
        address_prefix = "10.13.0.0/24"
        nsg_rules = {
          AllowClusterTrafficInBound = {
            priority                = 100
            direction               = "Inbound"
            protocol                = "*"
            remote_address_prefixes = ["10.13.0.0/24", "10.244.0.0/16"]
            local_address_prefixes  = ["10.13.0.0/24", "10.244.0.0/16"]
            destination_port_ranges = ["*"]
          }
        }
      }
    }
  }

  assert {
    condition = anytrue([
      for r in azurerm_network_security_group.this["nodes"].security_rule :
      r.name == "AllowClusterTrafficInBound" &&
      toset(r.destination_address_prefixes) == toset(["10.13.0.0/24", "10.244.0.0/16"])
    ])
    error_message = "local_address_prefixes must replace the subnet as the local side of the rule."
  }
}

run "internet_deny_can_be_turned_off" {
  command = plan

  variables {
    deny_internet_outbound = false
  }

  assert {
    condition = alltrue([
      for nsg in azurerm_network_security_group.this : !anytrue([for r in nsg.security_rule : r.name == "DenyInternetOutBound"])
    ])
    error_message = "deny_internet_outbound = false must drop the rule."
  }
}

run "rejects_reserved_priority" {
  command = plan

  variables {
    subnets = {
      app = {
        address_prefix = "10.10.1.0/24"
        nsg_rules = {
          TooLow = {
            priority                = 4000
            direction               = "Inbound"
            protocol                = "Tcp"
            remote_address_prefixes = ["10.11.0.0/24"]
            destination_port_ranges = ["443"]
          }
        }
      }
    }
  }

  expect_failures = [var.subnets]
}

run "rejects_service_tag_in_a_list" {
  command = plan

  variables {
    subnets = {
      app = {
        address_prefix = "10.10.1.0/24"
        nsg_rules = {
          Mixed = {
            priority                = 100
            direction               = "Inbound"
            protocol                = "Tcp"
            remote_address_prefixes = ["VirtualNetwork", "10.11.0.0/24"]
            destination_port_ranges = ["443"]
          }
        }
      }
    }
  }

  expect_failures = [var.subnets]
}

run "rejects_duplicate_priorities" {
  command = plan

  variables {
    subnets = {
      app = {
        address_prefix = "10.10.1.0/24"
        nsg_rules = {
          A = {
            priority                = 200
            direction               = "Inbound"
            protocol                = "Tcp"
            remote_address_prefixes = ["10.11.0.0/24"]
            destination_port_ranges = ["443"]
          }
          B = {
            priority                = 200
            direction               = "Inbound"
            protocol                = "Tcp"
            remote_address_prefixes = ["10.12.0.0/24"]
            destination_port_ranges = ["443"]
          }
        }
      }
    }
  }

  expect_failures = [var.subnets]
}
