# The role outputs depend on their policy attachments. Consumers such as the
# EKS cluster and node group then wait until the permissions actually exist,
# not just the empty role. On destroy the order reverses: the node group is
# deleted before its policies are detached.

output "cluster_role_arn" {
  description = "ARN of the EKS cluster IAM role (returned once its policies are attached)."
  value       = aws_iam_role.cluster.arn

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_iam_role_policy.cluster_kms,
  ]
}

output "node_role_arn" {
  description = "ARN of the worker node IAM role (returned once its policies are attached)."
  value       = aws_iam_role.node.arn

  depends_on = [aws_iam_role_policy_attachment.node]
}

output "node_role_name" {
  description = "Name of the worker node IAM role."
  value       = aws_iam_role.node.name
}

output "vpc_cni_role_arn" {
  description = "ARN of the IRSA role for the VPC CNI (returned once its policy is attached)."
  value       = aws_iam_role.vpc_cni.arn

  depends_on = [aws_iam_role_policy_attachment.vpc_cni]
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider for IRSA. Reuse it for other service-account roles."
  value       = aws_iam_openid_connect_provider.cluster.arn
}

output "cluster_admin_principal_arns" {
  description = "Principals that were given cluster-admin access entries."
  value       = [for e in aws_eks_access_entry.admin : e.principal_arn]
}
