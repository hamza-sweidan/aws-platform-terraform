# Offline unit tests with a mocked azurerm provider (no credentials needed).

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = { tenant_id = "00000000-0000-0000-0000-00000000bbbb" }
  }
}

variables {
  name                  = "aks-test"
  resource_group_name   = "rg-test"
  node_resource_group   = "rg-test-nodes"
  location              = "germanywestcentral"
  subnet_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-nodes"
  container_registry_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ContainerRegistry/registries/acrtest"
  admin_principal_ids   = ["00000000-0000-0000-0000-00000000aaaa"]
}

run "network_isolated_and_private" {
  command = plan

  assert {
    condition = (
      azurerm_kubernetes_cluster.this.network_profile[0].outbound_type == "none" &&
      azurerm_kubernetes_cluster.this.bootstrap_profile[0].artifact_source == "Cache" &&
      azurerm_kubernetes_cluster.this.bootstrap_profile[0].container_registry_id == var.container_registry_id
    )
    error_message = "No egress path: nodes must bootstrap from the private registry's cache."
  }

  assert {
    condition = (
      azurerm_kubernetes_cluster.this.private_cluster_enabled &&
      azurerm_kubernetes_cluster.this.private_cluster_public_fqdn_enabled == false
    )
    error_message = "The API server must be private, with no public FQDN."
  }

  assert {
    condition = (
      azurerm_kubernetes_cluster.this.network_profile[0].network_plugin_mode == "overlay" &&
      azurerm_kubernetes_cluster.this.network_profile[0].network_data_plane == "cilium" &&
      azurerm_kubernetes_cluster.this.network_profile[0].network_policy == "cilium"
    )
    error_message = "Azure CNI Overlay with the Cilium dataplane and NetworkPolicy."
  }
}

run "entra_id_only" {
  command = plan

  assert {
    condition = (
      azurerm_kubernetes_cluster.this.local_account_disabled &&
      azurerm_kubernetes_cluster.this.azure_active_directory_role_based_access_control[0].azure_rbac_enabled
    )
    error_message = "Local accounts off; Kubernetes authorization through Azure RBAC."
  }

  assert {
    condition = alltrue([
      for a in azurerm_role_assignment.cluster_admin :
      a.role_definition_name == "Azure Kubernetes Service RBAC Cluster Admin"
    ]) && length(azurerm_role_assignment.cluster_admin) == 1
    error_message = "Each admin gets the AKS RBAC Cluster Admin role on the cluster."
  }
}

run "identities_are_least_privilege" {
  command = plan

  assert {
    condition = (
      azurerm_role_assignment.kubelet_acr_pull.role_definition_name == "AcrPull" &&
      azurerm_role_assignment.kubelet_acr_pull.scope == var.container_registry_id
    )
    error_message = "The kubelet identity may only pull from the one registry."
  }

  assert {
    condition = (
      azurerm_role_assignment.control_plane_subnet.role_definition_name == "Network Contributor" &&
      azurerm_role_assignment.control_plane_subnet.scope == var.subnet_id
    )
    error_message = "The control plane gets Network Contributor on the node subnet only."
  }
}

run "nodes_are_private_and_sized_for_the_trial" {
  command = plan

  assert {
    condition = (
      azurerm_kubernetes_cluster.this.default_node_pool[0].vnet_subnet_id == var.subnet_id &&
      azurerm_kubernetes_cluster.this.default_node_pool[0].node_public_ip_enabled == false &&
      azurerm_kubernetes_cluster.this.default_node_pool[0].node_count == 2 &&
      toset(azurerm_kubernetes_cluster.this.default_node_pool[0].zones) == toset(["1", "2"])
    )
    error_message = "Two private nodes, one per zone, in the given subnet."
  }

  assert {
    condition = (
      azurerm_kubernetes_cluster.this.default_node_pool[0].os_disk_type == "Managed" &&
      azurerm_kubernetes_cluster.this.default_node_pool[0].os_disk_size_gb == 32
    )
    error_message = "Small managed OS disks (32 GB) instead of the 128 GB default."
  }
}

run "rejects_too_many_nodes" {
  command = plan

  variables {
    node_count = 4
  }

  expect_failures = [var.node_count]
}

run "rejects_a_non_registry_id" {
  command = plan

  variables {
    container_registry_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test"
  }

  expect_failures = [var.container_registry_id]
}
