# Offline unit tests: the AWS provider is mocked, so these run in CI with no
# credentials. `command = apply` only "applies" against the mock (nothing is
# created); it's used where an assertion needs computed IDs.
#   terraform init -backend=false && terraform test

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
  # The real provider still validates policy JSON, so the mock must be valid.
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  name               = "test"
  availability_zones = ["eu-central-1a", "eu-central-1b"]
}

run "private_subnets_have_no_route_out" {
  command = apply

  assert {
    # The only route the module creates is the public 0.0.0.0/0 to the IGW.
    condition     = aws_route.public_internet.route_table_id == aws_route_table.public.id
    error_message = "The internet route must only exist on the public route table."
  }

  assert {
    condition     = alltrue([for a in aws_route_table_association.private : a.route_table_id == aws_route_table.private.id])
    error_message = "Every private subnet must use the private route table (no default route)."
  }

  assert {
    condition     = aws_vpc_endpoint.s3.route_table_ids == toset([aws_route_table.private.id])
    error_message = "The S3 gateway endpoint belongs on the private route table only."
  }

  assert {
    condition = (
      aws_subnet.private[*].cidr_block == ["10.0.16.0/20", "10.0.32.0/20"] &&
      aws_subnet.public[*].cidr_block == ["10.0.0.0/24", "10.0.1.0/24"]
    )
    error_message = "Subnet layout changed: private /20s for pod IPs, public /24s."
  }

  assert {
    condition     = alltrue([for s in aws_subnet.public : s.map_public_ip_on_launch == false])
    error_message = "Public subnets must never auto-assign public IPs."
  }

  assert {
    condition     = aws_vpc.this.enable_dns_support && aws_vpc.this.enable_dns_hostnames
    error_message = "Interface endpoint private DNS needs both VPC DNS settings."
  }
}

run "interface_endpoints_are_private_and_https_only" {
  command = apply

  assert {
    condition     = toset(keys(aws_vpc_endpoint.interface)) == toset(["ecr.api", "ecr.dkr", "ec2", "sts", "logs"])
    error_message = "Default endpoints must be the five a private EKS cluster needs."
  }

  assert {
    condition = alltrue([
      for e in aws_vpc_endpoint.interface :
      e.private_dns_enabled && e.vpc_endpoint_type == "Interface" && toset(e.subnet_ids) == toset(aws_subnet.private[*].id)
    ])
    error_message = "Interface endpoints must use private DNS and live in every private subnet."
  }

  assert {
    condition     = aws_vpc_endpoint.interface["ecr.api"].service_name == "com.amazonaws.eu-central-1.ecr.api"
    error_message = "Service names must be built from the provider region."
  }

  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.endpoints_https.cidr_ipv4 == "10.0.0.0/16" &&
      aws_vpc_security_group_ingress_rule.endpoints_https.ip_protocol == "tcp" &&
      aws_vpc_security_group_ingress_rule.endpoints_https.from_port == 443 &&
      aws_vpc_security_group_ingress_rule.endpoints_https.to_port == 443
    )
    error_message = "The endpoint security group may only admit HTTPS from the VPC CIDR."
  }
}

run "s3_endpoint_only_reads_the_ecr_layer_bucket" {
  command = plan

  assert {
    condition = (
      toset(data.aws_iam_policy_document.s3_endpoint.statement[0].actions) == toset(["s3:GetObject"]) &&
      toset(data.aws_iam_policy_document.s3_endpoint.statement[0].resources) == toset(["arn:aws:s3:::prod-eu-central-1-starport-layer-bucket/*"])
    )
    error_message = "The S3 endpoint policy must allow only GetObject on the regional ECR layer bucket."
  }
}

run "flow_logs_are_opt_in_and_scoped" {
  command = plan

  assert {
    condition     = length(aws_flow_log.this) == 0 && length(aws_iam_role.flow_logs) == 0
    error_message = "Flow logs must be off unless enabled."
  }
}

run "flow_logs_role_trusts_only_this_account" {
  command = plan

  variables {
    enable_flow_logs = true
  }

  assert {
    condition = anytrue([
      for c in data.aws_iam_policy_document.flow_logs_assume[0].statement[0].condition :
      c.variable == "aws:SourceAccount" && toset(c.values) == toset(["111122223333"])
    ])
    error_message = "The flow logs role needs confused-deputy protection (aws:SourceAccount)."
  }

  assert {
    condition     = aws_flow_log.this[0].traffic_type == "ALL"
    error_message = "Flow logs must capture accepted and rejected traffic."
  }
}

run "rejects_a_single_az" {
  command = plan

  variables {
    availability_zones = ["eu-central-1a"]
  }

  expect_failures = [var.availability_zones]
}

run "rejects_an_az_that_doesnt_exist" {
  command = plan

  variables {
    availability_zones = ["eu-central-1a", "eu-central-1z"]
  }

  # AWS would only return the zone that exists.
  override_data {
    target = data.aws_availability_zones.selected
    values = { names = ["eu-central-1a"] }
  }

  expect_failures = [data.aws_availability_zones.selected]
}
