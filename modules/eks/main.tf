# Private EKS cluster with no internet egress:
#
# - API server endpoint is private only: reachable from inside the VPC, or
#   through an SSM tunnel via the bastion.
# - Managed node group in private subnets. Images come only from ECR via the
#   VPC endpoints created in modules/vpc.
# - Core add-ons (vpc-cni, kube-proxy, coredns) are EKS managed add-ons, so
#   Terraform manages everything through AWS APIs and never needs network
#   access to the private Kubernetes API.

locals {
  addon_names = toset(["vpc-cni", "kube-proxy", "coredns"])

  addon_versions = {
    for name in local.addon_names :
    name => lookup(var.addon_versions, name, data.aws_eks_addon_version.default[name].version)
  }
}

# The version EKS marks as default for this Kubernetes minor, not "latest".
# Plans stay stable until you change kubernetes_version or pin a version.
data "aws_eks_addon_version" "default" {
  for_each = local.addon_names

  addon_name         = each.key
  kubernetes_version = var.kubernetes_version
  most_recent        = false
}

# ---------------------------------------------------------------------------
# Control plane
# ---------------------------------------------------------------------------

# Created before the cluster. Otherwise EKS creates this log group itself
# with never-expire retention and no CMK, and Terraform can't manage it.
resource "aws_cloudwatch_log_group" "cluster" {
  #checkov:skip=CKV_AWS_338:Lab environment: control-plane logs are kept for var.log_retention_days (default 30). Production would set 365+ for audit.
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = var.tags
}

# Extra security group on the control-plane ENIs, listing which in-VPC
# clients (besides the nodes) may call the API. EKS also attaches its own
# managed cluster security group, which covers node <-> control plane.
resource "aws_security_group" "cluster_api" {
  name_prefix = "${var.cluster_name}-api-"
  description = "Private EKS API endpoint: approved in-VPC clients on 443"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.cluster_name}-api" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "cluster_api" {
  count = length(var.api_client_security_group_ids)

  security_group_id            = aws_security_group.cluster_api.id
  referenced_security_group_id = var.api_client_security_group_ids[count.index]
  description                  = "Kubernetes API from approved client security group"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

resource "aws_eks_cluster" "this" {
  #checkov:skip=CKV_AWS_339:Checkov 3.3.19 hardcodes supported versions only up to 1.35. `aws eks describe-cluster-versions` lists 1.36 as the EKS default in STANDARD_SUPPORT until 2027-08, and upgrade_policy below keeps the cluster out of extended support.
  name                      = var.cluster_name
  version                   = var.kubernetes_version
  role_arn                  = var.cluster_role_arn
  enabled_cluster_log_types = var.enabled_log_types

  # Skip the unmanaged default vpc-cni/kube-proxy/coredns and install them
  # below as managed add-ons, so their versions and config live in code.
  bootstrap_self_managed_addons = false

  access_config {
    # Access entries only; the aws-auth ConfigMap is ignored.
    authentication_mode = "API"
    # The IAM identity that runs `apply` gets no hidden admin rights.
    # Admins are explicit access entries in modules/iam.
    bootstrap_cluster_creator_admin_permissions = false
  }

  vpc_config {
    subnet_ids              = var.subnet_ids
    security_group_ids      = [aws_security_group.cluster_api.id]
    endpoint_private_access = true
    endpoint_public_access  = false
  }

  kubernetes_network_config {
    ip_family         = "ipv4"
    service_ipv4_cidr = var.service_ipv4_cidr
  }

  encryption_config {
    resources = ["secrets"]

    provider {
      key_arn = var.kms_key_arn
    }
  }

  # When standard support ends, EKS upgrades the cluster automatically
  # instead of moving it to extended support, which costs 6x ($0.60/h).
  upgrade_policy {
    support_type = "STANDARD"
  }

  tags = var.tags

  depends_on = [aws_cloudwatch_log_group.cluster]
}

# ---------------------------------------------------------------------------
# Add-ons that must exist before nodes can become Ready
# ---------------------------------------------------------------------------

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  addon_version               = local.addon_versions["vpc-cni"]
  service_account_role_arn    = var.vpc_cni_role_arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    enableNetworkPolicy = tostring(var.enable_network_policy)
  })

  tags = var.tags
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  addon_version               = local.addon_versions["kube-proxy"]
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Managed node group
# ---------------------------------------------------------------------------

resource "aws_launch_template" "node" {
  name_prefix            = "${var.cluster_name}-node-"
  description            = "EKS managed node group template for ${var.cluster_name}: IMDSv2 with hop limit 1, encrypted gp3 root volume"
  update_default_version = true

  # No image_id, user data, key pair or security groups here. EKS supplies the
  # AMI (from ami_type), the nodeadm bootstrap config and the cluster security
  # group. Setting any of them would make this a custom-AMI node group.

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.node_disk_size_gib
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.cluster_name}-node" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = "${var.cluster_name}-node" })
  }

  tags = var.tags
}

resource "aws_eks_node_group" "default" {
  cluster_name           = aws_eks_cluster.this.name
  node_group_name_prefix = "default-"
  node_role_arn          = var.node_role_arn
  subnet_ids             = var.subnet_ids
  version                = aws_eks_cluster.this.version
  ami_type               = var.node_ami_type
  capacity_type          = var.node_capacity_type
  instance_types         = var.node_instance_types

  scaling_config {
    min_size     = var.node_min_size
    desired_size = var.node_desired_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  tags = var.tags

  lifecycle {
    # Replacements (e.g. a new instance type) create the new group first,
    # then drain and delete the old one.
    create_before_destroy = true
    # An autoscaler owns desired_size after creation. Don't fight it.
    ignore_changes = [scaling_config[0].desired_size]
  }

  # Nodes stay NotReady until the CNI runs, and a node group that never
  # becomes Ready fails creation, so the CNI add-on goes first.
  depends_on = [
    aws_eks_addon.vpc_cni,
    aws_eks_addon.kube_proxy,
  ]
}

# CoreDNS is a Deployment. Without nodes it stays Degraded and the add-on
# create would time out, so it's installed after the node group.
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  addon_version               = local.addon_versions["coredns"]
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags

  depends_on = [aws_eks_node_group.default]
}
