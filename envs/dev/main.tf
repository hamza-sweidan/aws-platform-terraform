# dev environment: composes the reusable modules into one private, zero-egress
# EKS platform. The environment only chooses names, sizes and toggles; all
# resource logic lives in modules/.

locals {
  name = "${var.project}-${var.environment}"

  default_tags = {
    Project     = var.project
    Environment = var.environment
    Owner       = var.owner
    ManagedBy   = "Terraform"
  }

  # Interface endpoints a private EKS cluster needs (AWS "private clusters" doc).
  core_endpoints = ["ecr.api", "ecr.dkr", "ec2", "sts", "logs"]
  # Only paid for while the bastion exists.
  bastion_endpoints = ["ssm", "ssmmessages", "ec2messages"]

  interface_endpoints = toset(concat(
    local.core_endpoints,
    var.enable_bastion ? local.bastion_endpoints : [],
  ))

  # Log group names are fixed here because the KMS key policy must name them
  # before they exist. EKS requires /aws/eks/<cluster>/cluster exactly.
  log_groups = {
    eks       = "/aws/eks/${local.name}/cluster"
    flow_logs = "/aws/vpc/${local.name}/flow-logs"
  }
}

module "kms" {
  source = "../../modules/kms"

  name                       = local.name
  cloudwatch_log_group_names = values(local.log_groups)
}

module "vpc" {
  source = "../../modules/vpc"

  name                = local.name
  cidr_block          = var.vpc_cidr
  availability_zones  = var.availability_zones
  interface_endpoints = local.interface_endpoints

  enable_flow_logs         = var.enable_flow_logs
  flow_logs_log_group_name = local.log_groups.flow_logs
  flow_logs_kms_key_arn    = module.kms.key_arn
  flow_logs_retention_days = var.log_retention_days
}

module "iam" {
  source = "../../modules/iam"

  name                         = local.name
  cluster_name                 = module.eks.cluster_name
  cluster_oidc_issuer_url      = module.eks.oidc_issuer_url
  kms_key_arn                  = module.kms.key_arn
  cluster_admin_principal_arns = var.cluster_admin_principal_arns
}

module "bastion" {
  source = "../../modules/bastion"
  count  = var.enable_bastion ? 1 : 0

  name           = "${local.name}-bastion"
  vpc_id         = module.vpc.vpc_id
  vpc_cidr_block = module.vpc.vpc_cidr_block
  # private_subnet_ids waits for the endpoints, including the SSM ones.
  subnet_id = module.vpc.private_subnet_ids[0]
}

module "eks" {
  source = "../../modules/eks"

  cluster_name       = local.name
  kubernetes_version = var.kubernetes_version
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnet_ids

  cluster_role_arn = module.iam.cluster_role_arn
  node_role_arn    = module.iam.node_role_arn
  vpc_cni_role_arn = module.iam.vpc_cni_role_arn
  kms_key_arn      = module.kms.key_arn

  log_retention_days            = var.log_retention_days
  api_client_security_group_ids = var.enable_bastion ? [module.bastion[0].security_group_id] : []

  node_instance_types = var.node_instance_types
  node_capacity_type  = var.node_capacity_type
  node_min_size       = var.node_min_size
  node_desired_size   = var.node_desired_size
  node_max_size       = var.node_max_size
  node_tags           = local.default_tags
}
