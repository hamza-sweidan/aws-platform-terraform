output "location" {
  description = "Azure region."
  value       = var.location
}

output "resource_group_names" {
  description = "Resource group per VNet."
  value = merge(
    { hub = azurerm_resource_group.hub.name },
    { for k, rg in azurerm_resource_group.spoke : k => rg.name },
  )
}

output "address_plan" {
  description = "VNet and subnet CIDRs, by VNet and subnet key."
  value = merge(
    { hub = { vnet = var.hub_address_space, shared = local.hub_shared_prefix } },
    { for k, s in var.spokes : k => merge({ vnet = s.address_space }, local.spoke_subnets[k]) },
  )
}

output "hub_vnet_id" {
  description = "Hub VNet ID."
  value       = module.hub.id
}

output "spoke_vnet_ids" {
  description = "Spoke VNet IDs by spoke key."
  value       = { for k, m in module.spoke : k => m.id }
}

output "subnet_ids" {
  description = "Subnet IDs by VNet key, then subnet key."
  value = merge(
    { hub = module.hub.subnet_ids },
    { for k, m in module.spoke : k => m.subnet_ids },
  )
}

output "network_security_group_ids" {
  description = "NSG IDs by VNet key, then subnet key."
  value = merge(
    { hub = module.hub.network_security_group_ids },
    { for k, m in module.spoke : k => m.network_security_group_ids },
  )
}

output "peering_names" {
  description = "Hub and spoke link names per spoke."
  value       = { for k, p in module.peering : k => p.names }
}

output "tag_policy_definition_id" {
  description = "Custom required-tags policy definition ID."
  value       = module.tag_policy.policy_definition_id
}

output "tag_policy_assignment_ids" {
  description = "Required-tags policy assignment IDs by resource group key."
  value       = module.tag_policy.assignment_ids
}

output "verify_commands" {
  description = "az commands (bash) that check peering, NSG rules and the tag policy. Only step 5 changes anything: it creates and immediately deletes an empty NSG, which is free."
  value       = <<-EOT
    # 1. Both links of every peering are Connected and in sync
    az network vnet peering list -g ${azurerm_resource_group.hub.name} --vnet-name ${module.hub.name} \
      --query "[].{name:name, state:peeringState, sync:peeringSyncLevel}" -o table

    # 2. Spokes only learn the hub's range, never each other's (peering isn't transitive)
    ${join("\n", [for m in values(module.spoke) : "az network vnet peering list -g ${m.resource_group_name} --vnet-name ${m.name} --query \"[].remoteAddressSpace.addressPrefixes\" -o tsv"])}

    # 3. Baseline + custom NSG rules on a spoke data subnet
    az network nsg rule list -g ${azurerm_resource_group.spoke[keys(var.spokes)[0]].name} \
      --nsg-name nsg-${var.project}-${keys(var.spokes)[0]}-${var.environment}-data \
      --query "sort_by(@, &priority)[].{prio:priority, dir:direction, access:access, name:name, src:sourceAddressPrefix || join(',', sourceAddressPrefixes), port:destinationPortRange}" -o table

    # 4. The tag policy denies an untagged resource (expect RequestDisallowedByPolicy; nothing is created)
    az network nsg create -g ${azurerm_resource_group.hub.name} -n nsg-policy-test -l ${var.location}

    # 5. ...and allows a tagged one. Delete it straight away.
    az network nsg create -g ${azurerm_resource_group.hub.name} -n nsg-policy-test -l ${var.location} \
      --tags ${join(" ", [for k, v in local.tags : "${k}=${v}"])} \
      && az network nsg delete -g ${azurerm_resource_group.hub.name} -n nsg-policy-test
  EOT
}
