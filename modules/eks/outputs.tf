output "cluster_name" {
  description = "Name of the EKS cluster. Referencing it creates a dependency on the cluster."
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "ARN of the EKS cluster."
  value       = aws_eks_cluster.this.arn
}

output "cluster_version" {
  description = "Kubernetes version of the control plane."
  value       = aws_eks_cluster.this.version
}

output "cluster_endpoint" {
  description = "Private API server endpoint URL. It resolves to private IPs and is reachable only from inside the VPC."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_endpoint_host" {
  description = "API server hostname without scheme, for SSM port forwarding and kubectl --tls-server-name."
  value       = trimprefix(aws_eks_cluster.this.endpoint, "https://")
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded cluster CA certificate."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL for IRSA."
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "cluster_security_group_id" {
  description = "EKS-managed cluster security group, shared by the control-plane ENIs and the managed nodes."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "api_security_group_id" {
  description = "Additional security group controlling which in-VPC clients may reach the API."
  value       = aws_security_group.cluster_api.id
}

output "node_group_name" {
  description = "Name of the default managed node group."
  value       = aws_eks_node_group.default.node_group_name
}

output "log_group_name" {
  description = "CloudWatch log group receiving control-plane logs."
  value       = aws_cloudwatch_log_group.cluster.name
}

output "addon_versions" {
  description = "Resolved add-on versions."
  value       = local.addon_versions
}
