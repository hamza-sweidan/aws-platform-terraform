# Identity and authorization for the EKS platform:
#
#   1. Cluster role  - assumed by the EKS service to manage AWS resources
#   2. Node role     - assumed by worker EC2 instances (kubelet, image pulls)
#   3. VPC CNI role  - IRSA role for the aws-node DaemonSet only
#   4. Access entries - which humans are cluster-admin (no aws-auth ConfigMap)
#
# This module and modules/eks reference each other (roles -> cluster ->
# access entries). That's fine because Terraform builds its graph per
# resource, not per module: cluster role -> cluster -> access entry has no cycle.

data "aws_partition" "current" {}

locals {
  partition   = data.aws_partition.current.partition
  aws_managed = "arn:${local.partition}:iam::aws:policy"

  # OIDC condition keys are the issuer URL without the scheme,
  # e.g. oidc.eks.eu-central-1.amazonaws.com/id/ABC123:sub
  oidc_issuer_host = replace(var.cluster_oidc_issuer_url, "https://", "")
}

# ---------------------------------------------------------------------------
# 1. Cluster role
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "eks_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name                 = "${var.name}-eks-cluster"
  description          = "Assumed by the EKS control plane to manage ENIs, load balancers and encryption for ${var.name}"
  assume_role_policy   = data.aws_iam_policy_document.eks_assume.json
  max_session_duration = 3600

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "${local.aws_managed}/AmazonEKSClusterPolicy"
}

# Custom least-privilege policy: only the four KMS actions EKS needs for
# envelope encryption, and only on the one platform key.
data "aws_iam_policy_document" "cluster_kms" {
  statement {
    sid = "EnvelopeEncryptKubernetesSecrets"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ListGrants",
      "kms:DescribeKey",
    ]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "cluster_kms" {
  name   = "kms-secrets-encryption"
  role   = aws_iam_role.cluster.id
  policy = data.aws_iam_policy_document.cluster_kms.json
}

# ---------------------------------------------------------------------------
# 2. Node role
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name                 = "${var.name}-eks-node"
  description          = "Worker node instance role for ${var.name}: join the cluster and pull images from ECR"
  assume_role_policy   = data.aws_iam_policy_document.ec2_assume.json
  max_session_duration = 3600

  tags = var.tags
}

# Deliberately missing, compared with most tutorials:
# - AmazonEKS_CNI_Policy: moved to the IRSA role below, so the ENI/IP
#   permissions belong to aws-node only, not to anything that can reach the
#   node's instance metadata.
# - AmazonEC2ContainerRegistryReadOnly: replaced by the narrower PullOnly
#   policy (no List/Describe of every repository in the account).
# - AmazonSSMManagedInstanceCore: nodes aren't managed through SSM; the
#   optional bastion is the only SSM target.
resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEC2ContainerRegistryPullOnly",
  ])

  role       = aws_iam_role.node.name
  policy_arn = "${local.aws_managed}/${each.key}"
}

# ---------------------------------------------------------------------------
# 3. IRSA for the VPC CNI
# ---------------------------------------------------------------------------

# The OIDC provider is created from wherever Terraform runs (which has
# internet). Inside the VPC, pods only need STS: STS fetches the cluster's
# signing keys from inside AWS.
resource "aws_iam_openid_connect_provider" "cluster" {
  url            = var.cluster_oidc_issuer_url
  client_id_list = ["sts.amazonaws.com"]

  tags = var.tags
}

data "aws_iam_policy_document" "vpc_cni_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.cluster.arn]
    }

    # Only the aws-node service account in kube-system, and only tokens
    # minted for STS, can assume this role.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:sub"
      values   = ["system:serviceaccount:kube-system:aws-node"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "vpc_cni" {
  name                 = "${var.name}-vpc-cni"
  description          = "IRSA role for kube-system/aws-node (Amazon VPC CNI) in ${var.name}"
  assume_role_policy   = data.aws_iam_policy_document.vpc_cni_assume.json
  max_session_duration = 3600

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "vpc_cni" {
  role       = aws_iam_role.vpc_cni.name
  policy_arn = "${local.aws_managed}/AmazonEKS_CNI_Policy"
}

# ---------------------------------------------------------------------------
# 4. EKS access entries (authentication_mode = "API")
# ---------------------------------------------------------------------------

resource "aws_eks_access_entry" "admin" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = var.cluster_name
  principal_arn = each.value
  type          = "STANDARD"

  tags = var.tags
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = var.cluster_name
  principal_arn = aws_eks_access_entry.admin[each.key].principal_arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}
