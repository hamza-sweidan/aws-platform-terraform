output "region" {
  description = "AWS region."
  value       = var.region
}

output "vpc_id" {
  description = "VPC ID."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (nodes and control-plane ENIs)."
  value       = module.vpc.private_subnet_ids
}

output "interface_endpoints" {
  description = "Interface VPC endpoints by service."
  value       = module.vpc.interface_endpoint_ids
}

output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_arn" {
  description = "EKS cluster ARN (also the kubeconfig cluster entry name)."
  value       = module.eks.cluster_arn
}

output "cluster_version" {
  description = "Kubernetes version."
  value       = module.eks.cluster_version
}

output "cluster_endpoint" {
  description = "Private API endpoint (reachable only from inside the VPC)."
  value       = module.eks.cluster_endpoint
}

output "addon_versions" {
  description = "Resolved EKS add-on versions."
  value       = module.eks.addon_versions
}

output "kms_key_arn" {
  description = "Platform KMS key ARN."
  value       = module.kms.key_arn
}

output "ecr_repository_urls" {
  description = "Mirror repository URLs by name."
  value       = { for k, r in aws_ecr_repository.mirror : k => r.repository_url }
}

output "bastion_instance_id" {
  description = "SSM bastion instance ID, or null when enable_bastion = false."
  value       = one(module.bastion[*].instance_id)
}

output "ssm_tunnel_command" {
  description = "Run in its own terminal (bash) to forward localhost:8443 to the private API through the bastion."
  value = var.enable_bastion ? join(" ", [
    "aws ssm start-session",
    "--region ${var.region}",
    "--target ${module.bastion[0].instance_id}",
    "--document-name AWS-StartPortForwardingSessionToRemoteHost",
    "--parameters '{\"host\":[\"${module.eks.cluster_endpoint_host}\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"8443\"]}'",
  ]) : "Set enable_bastion = true to get a tunnel to the private API."
}

output "kubeconfig_commands" {
  description = "Point kubectl at the SSM tunnel while still verifying the API certificate against its real hostname."
  value       = <<-EOT
    aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name} --alias ${module.eks.cluster_name}
    kubectl config set-cluster ${module.eks.cluster_arn} --server=https://127.0.0.1:8443 --tls-server-name=${module.eks.cluster_endpoint_host}
  EOT
}
