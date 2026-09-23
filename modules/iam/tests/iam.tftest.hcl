# Offline unit tests with a mocked AWS provider (no credentials needed).

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  # The real provider still validates policy JSON, so the mock must be valid.
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  name                         = "test"
  cluster_name                 = "test"
  cluster_oidc_issuer_url      = "https://oidc.eks.eu-central-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE"
  kms_key_arn                  = "arn:aws:kms:eu-central-1:111122223333:key/11111111-2222-3333-4444-555555555555"
  cluster_admin_principal_arns = ["arn:aws:iam::111122223333:user/admin"]
}

run "node_role_is_least_privilege" {
  command = plan

  assert {
    condition = toset([for a in aws_iam_role_policy_attachment.node : a.policy_arn]) == toset([
      "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
      "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
    ])
    error_message = "The node role gets exactly WorkerNode + ECR PullOnly: no CNI policy, no ECR ReadOnly, no SSM."
  }

  assert {
    condition     = aws_iam_role_policy_attachment.vpc_cni.policy_arn == "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
    error_message = "The CNI policy belongs on the IRSA role."
  }
}

run "vpc_cni_role_trusts_only_aws_node" {
  command = plan

  assert {
    condition = anytrue([
      for c in data.aws_iam_policy_document.vpc_cni_assume.statement[0].condition :
      c.variable == "oidc.eks.eu-central-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE:sub" &&
      toset(c.values) == toset(["system:serviceaccount:kube-system:aws-node"])
    ])
    error_message = "Only kube-system/aws-node may assume the CNI role (issuer host without https://)."
  }

  assert {
    condition = anytrue([
      for c in data.aws_iam_policy_document.vpc_cni_assume.statement[0].condition :
      endswith(c.variable, ":aud") && toset(c.values) == toset(["sts.amazonaws.com"])
    ])
    error_message = "The CNI role must require tokens minted for STS."
  }
}

run "cluster_kms_access_is_one_key" {
  command = plan

  assert {
    condition     = toset(data.aws_iam_policy_document.cluster_kms.statement[0].resources) == toset([var.kms_key_arn])
    error_message = "The cluster role's KMS permissions must be scoped to the platform key."
  }
}

run "one_admin_entry_per_principal" {
  command = plan

  variables {
    cluster_admin_principal_arns = [
      "arn:aws:iam::111122223333:user/admin",
      "arn:aws:iam::111122223333:role/breakglass",
    ]
  }

  assert {
    condition     = length(aws_eks_access_entry.admin) == 2 && length(aws_eks_access_policy_association.admin) == 2
    error_message = "Each admin principal needs an access entry and a policy association."
  }

  assert {
    condition = alltrue([
      for a in aws_eks_access_policy_association.admin :
      a.policy_arn == "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy" && a.access_scope[0].type == "cluster"
    ])
    error_message = "Admins get the cluster-scoped AmazonEKSClusterAdminPolicy."
  }
}

run "rejects_no_admins" {
  command = plan

  variables {
    cluster_admin_principal_arns = []
  }

  expect_failures = [var.cluster_admin_principal_arns]
}

run "rejects_non_https_issuer" {
  command = plan

  variables {
    cluster_oidc_issuer_url = "oidc.eks.eu-central-1.amazonaws.com/id/EXAMPLE"
  }

  expect_failures = [var.cluster_oidc_issuer_url]
}
