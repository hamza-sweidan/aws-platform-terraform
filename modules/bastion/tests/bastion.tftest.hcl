# Offline unit tests with a mocked AWS provider (no credentials needed).

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
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
  name           = "test-bastion"
  vpc_id         = "vpc-0123456789abcdef0"
  vpc_cidr_block = "10.0.0.0/16"
  subnet_id      = "subnet-aaaaaaaaaaaaaaaaa"
}

run "no_public_ip_no_ssh_imdsv2" {
  command = plan

  # key_name is provider-computed, so a plan can't prove it's unset; the module
  # simply never passes one.
  assert {
    condition     = aws_instance.this.associate_public_ip_address == false
    error_message = "The bastion must have no public IP."
  }

  assert {
    condition = (
      aws_instance.this.metadata_options[0].http_tokens == "required" &&
      aws_instance.this.metadata_options[0].http_put_response_hop_limit == 1
    )
    error_message = "IMDSv2 only, hop limit 1."
  }

  assert {
    condition     = aws_instance.this.root_block_device[0].encrypted == true
    error_message = "The root volume must be encrypted."
  }
}

run "egress_is_https_to_the_vpc_only" {
  command = plan

  assert {
    condition = (
      aws_vpc_security_group_egress_rule.https_to_vpc.cidr_ipv4 == "10.0.0.0/16" &&
      aws_vpc_security_group_egress_rule.https_to_vpc.from_port == 443 &&
      aws_vpc_security_group_egress_rule.https_to_vpc.to_port == 443
    )
    error_message = "The only egress is HTTPS to the VPC (SSM endpoints and the EKS API)."
  }

  assert {
    condition     = aws_iam_role_policy_attachment.ssm_core.policy_arn == "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    error_message = "The instance role gets only the SSM core policy."
  }
}

run "rejects_graviton_instance_types" {
  command = plan

  variables {
    instance_type = "t4g.micro"
  }

  expect_failures = [var.instance_type]
}
