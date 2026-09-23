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

output "aks_cluster_name" {
  description = "AKS cluster name, or null when enable_aks = false."
  value       = one(module.aks[*].name)
}

output "aks_resource_group_name" {
  description = "Resource group of the AKS cluster, registry and identities, or null."
  value       = one(azurerm_resource_group.aks[*].name)
}

output "acr_name" {
  description = "Private registry name, or null."
  value       = one(module.acr[*].name)
}

output "acr_login_server" {
  description = "Private registry login server, or null."
  value       = one(module.acr[*].login_server)
}

output "aks_verify_commands" {
  description = "az commands (bash) that check the AKS cluster and run the offline demo through az aks command invoke."
  value = var.enable_aks ? join("\n", [
    "# 1. Network isolated: no egress path, system images from the private ACR cache, private API",
    "az aks show -g ${azurerm_resource_group.aks[0].name} -n ${module.aks[0].name} --query \"{outbound:networkProfile.outboundType, artifacts:bootstrapProfile.artifactSource, private:apiServerAccessProfile.enablePrivateCluster, localAccounts:disableLocalAccounts}\" -o table",
    "",
    "# 2. Nodes Ready with private IPs only (kubectl runs inside the cluster)",
    "az aks command invoke -g ${azurerm_resource_group.aks[0].name} -n ${module.aks[0].name} --command \"kubectl get nodes -o wide\"",
    "",
    "# 3. Mirror the demo image into the private registry (ACR pulls it server-side)",
    "az acr import --name ${module.acr[0].name} --source docker.io/nginxinc/nginx-unprivileged:1.30-alpine --image mirror/nginx-unprivileged:1.30-alpine",
    "",
    "# 4. Deploy the same manifests as the EKS demo, then prove there's no way out",
    "export DEMO_IMAGE=${module.acr[0].login_server}/mirror/nginx-unprivileged:1.30-alpine",
    "envsubst '$DEMO_IMAGE' < k8s/deployment.yaml > /tmp/deployment.yaml",
    "az aks command invoke -g ${azurerm_resource_group.aks[0].name} -n ${module.aks[0].name} --file k8s/namespace.yaml --file /tmp/deployment.yaml --file k8s/service.yaml --file k8s/networkpolicy.yaml --command \"kubectl apply -f namespace.yaml && kubectl apply -f deployment.yaml -f service.yaml -f networkpolicy.yaml && kubectl -n offline-demo rollout status deploy/web --timeout=180s\"",
    "az aks command invoke -g ${azurerm_resource_group.aks[0].name} -n ${module.aks[0].name} --command \"kubectl -n offline-demo exec deploy/web -- wget -qO- -T 5 http://web | grep -i title; kubectl -n offline-demo exec deploy/web -- wget -qO- -T 5 https://example.com || echo 'no internet egress (expected)'\"",
  ]) : "Set enable_aks = true to create the cluster."
}
