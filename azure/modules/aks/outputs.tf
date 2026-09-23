output "id" {
  description = "Cluster resource ID."
  value       = azurerm_kubernetes_cluster.this.id
}

output "name" {
  description = "Cluster name."
  value       = azurerm_kubernetes_cluster.this.name
}

output "node_resource_group" {
  description = "AKS-managed resource group holding the node VMs and the API server private endpoint."
  value       = azurerm_kubernetes_cluster.this.node_resource_group
}

output "private_fqdn" {
  description = "Private API server FQDN (resolves only inside the cluster VNet)."
  value       = azurerm_kubernetes_cluster.this.private_fqdn
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL for workload identity federation."
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "kubelet_principal_id" {
  description = "Object ID of the kubelet identity (holds AcrPull on the registry)."
  value       = azurerm_user_assigned_identity.kubelet.principal_id
}
