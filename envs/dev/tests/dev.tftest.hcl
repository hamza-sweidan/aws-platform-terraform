# Offline plan of the whole AWS environment with a mocked provider: no
# credentials and no backend (terraform init -backend=false && terraform test).

mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { region = "eu-central-1" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["eu-central-1a", "eu-central-1b"] }
  }
  mock_data "aws_eks_addon_version" {
    defaults = { version = "v1.0.0-eksbuild.1" }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { insecure_value = "ami-0123456789abcdef0" }
  }
  # The real provider still validates policy JSON, so the mock must be valid.
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  owner                        = "test-owner"
  cluster_admin_principal_arns = ["arn:aws:iam::111122223333:user/admin"]
}

run "bastion_off_means_core_endpoints_only" {
  command = plan

  assert {
    condition     = toset(keys(output.interface_endpoints)) == toset(["ecr.api", "ecr.dkr", "ec2", "sts", "logs"])
    error_message = "Without the bastion, only the five core EKS endpoints should be paid for."
  }

  assert {
    condition     = output.bastion_instance_id == null && startswith(output.ssm_tunnel_command, "Set enable_bastion")
    error_message = "No bastion and no tunnel command unless enable_bastion = true."
  }

  assert {
    condition     = output.cluster_name == "aws-platform-dev"
    error_message = "Resource names come from <project>-<environment>."
  }
}

run "bastion_on_adds_the_ssm_endpoints" {
  command = plan

  variables {
    enable_bastion = true
  }

  assert {
    condition = toset(keys(output.interface_endpoints)) == toset([
      "ecr.api", "ecr.dkr", "ec2", "sts", "logs", "ssm", "ssmmessages", "ec2messages",
    ])
    error_message = "The bastion needs the three SSM endpoints on top of the core five."
  }
}

run "mirror_repositories_are_immutable_and_scanned" {
  command = plan

  assert {
    condition = alltrue([
      for r in aws_ecr_repository.mirror :
      r.image_tag_mutability == "IMMUTABLE" && r.image_scanning_configuration[0].scan_on_push
    ])
    error_message = "Mirror repositories must have immutable tags and scan on push."
  }
}

run "rejects_an_az_outside_the_region" {
  command = plan

  variables {
    availability_zones = ["eu-central-1a", "eu-west-1a"]
  }

  expect_failures = [var.availability_zones]
}

run "rejects_no_admins" {
  command = plan

  variables {
    cluster_admin_principal_arns = []
  }

  expect_failures = [var.cluster_admin_principal_arns]
}
