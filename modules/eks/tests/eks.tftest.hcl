# Offline unit tests with a mocked AWS provider (no credentials needed).

mock_provider "aws" {
  mock_data "aws_eks_addon_version" {
    defaults = { version = "v1.0.0-eksbuild.1" }
  }
}

variables {
  cluster_name     = "test"
  vpc_id           = "vpc-0123456789abcdef0"
  subnet_ids       = ["subnet-aaaaaaaaaaaaaaaaa", "subnet-bbbbbbbbbbbbbbbbb"]
  cluster_role_arn = "arn:aws:iam::111122223333:role/test-eks-cluster"
  node_role_arn    = "arn:aws:iam::111122223333:role/test-eks-node"
  vpc_cni_role_arn = "arn:aws:iam::111122223333:role/test-vpc-cni"
  kms_key_arn      = "arn:aws:kms:eu-central-1:111122223333:key/11111111-2222-3333-4444-555555555555"
}

run "api_endpoint_is_private_only" {
  command = plan

  assert {
    condition = (
      aws_eks_cluster.this.vpc_config[0].endpoint_private_access == true &&
      aws_eks_cluster.this.vpc_config[0].endpoint_public_access == false
    )
    error_message = "The Kubernetes API must be reachable only from inside the VPC."
  }
}

run "access_is_explicit_and_secrets_are_encrypted" {
  command = plan

  assert {
    condition = (
      aws_eks_cluster.this.access_config[0].authentication_mode == "API" &&
      aws_eks_cluster.this.access_config[0].bootstrap_cluster_creator_admin_permissions == false
    )
    error_message = "Access entries only, and no hidden admin for whoever ran apply."
  }

  assert {
    condition = (
      toset(aws_eks_cluster.this.encryption_config[0].resources) == toset(["secrets"]) &&
      aws_eks_cluster.this.encryption_config[0].provider[0].key_arn == var.kms_key_arn
    )
    error_message = "Kubernetes Secrets must be envelope-encrypted with the platform key."
  }

  assert {
    condition     = aws_eks_cluster.this.upgrade_policy[0].support_type == "STANDARD"
    error_message = "The cluster must never drift into paid extended support."
  }

  assert {
    condition     = aws_eks_cluster.this.bootstrap_self_managed_addons == false
    error_message = "Core add-ons must be EKS managed add-ons, not the unmanaged defaults."
  }

  assert {
    condition     = aws_cloudwatch_log_group.cluster.name == "/aws/eks/test/cluster" && aws_cloudwatch_log_group.cluster.kms_key_id == var.kms_key_arn
    error_message = "The control-plane log group must be pre-created with the exact EKS name and the CMK."
  }
}

run "nodes_are_hardened" {
  command = plan

  assert {
    condition = (
      aws_launch_template.node.metadata_options[0].http_tokens == "required" &&
      aws_launch_template.node.metadata_options[0].http_put_response_hop_limit == 1
    )
    error_message = "Nodes need IMDSv2 with hop limit 1, so pods can't reach the node role."
  }

  assert {
    condition = (
      aws_launch_template.node.block_device_mappings[0].ebs[0].encrypted == "true" &&
      aws_launch_template.node.block_device_mappings[0].ebs[0].volume_type == "gp3"
    )
    error_message = "Node root volumes must be encrypted gp3."
  }

  assert {
    condition     = aws_launch_template.node.image_id == null && aws_launch_template.node.key_name == null
    error_message = "No custom AMI and no SSH key: EKS supplies the AMI, and there is no SSH."
  }

  assert {
    condition     = toset(aws_eks_node_group.default.subnet_ids) == toset(var.subnet_ids)
    error_message = "Nodes must run in the private subnets passed in."
  }

  assert {
    condition     = aws_eks_addon.vpc_cni.service_account_role_arn == var.vpc_cni_role_arn
    error_message = "The VPC CNI must use its IRSA role, not the node role."
  }
}

run "api_clients_are_opt_in" {
  command = plan

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.cluster_api) == 0
    error_message = "No extra API clients unless a security group is passed in."
  }
}

run "rejects_desired_above_max" {
  command = plan

  variables {
    node_desired_size = 5
    node_max_size     = 3
  }

  expect_failures = [var.node_desired_size]
}
