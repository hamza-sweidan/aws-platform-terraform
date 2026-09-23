# A two-tier VPC for a private EKS cluster with no internet egress:
#
# - Private subnets have no default route. The only ways out are the S3
#   gateway endpoint and the interface endpoints created here.
# - Public subnets exist only for future internet-facing load balancers.
#   Nothing is launched in them and they never assign public IPs.
# - No NAT gateway.

data "aws_region" "current" {}

data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

# Look up exactly the requested zones (an allowlist on zone-name), so the result
# can't grow when AWS adds a zone. The opt-in filter rejects Local and
# Wavelength Zones, which EKS doesn't support.
data "aws_availability_zones" "selected" {
  state = "available"

  filter {
    name   = "zone-name"
    values = var.availability_zones
  }

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }

  lifecycle {
    postcondition {
      condition     = length(self.names) == length(var.availability_zones)
      error_message = "One or more availability_zones don't exist in this region, aren't available, or are Local/Wavelength Zones."
    }
  }
}

locals {
  region = data.aws_region.current.region
  # Read from the data source, not the variable, so subnets only use zones
  # that passed the postcondition. AWS returns them sorted by name.
  azs      = data.aws_availability_zones.selected.names
  az_count = length(local.azs)

  # With a /16: public = 10.0.0.0/24, 10.0.1.0/24 (inside the first /20)
  #             private = 10.0.16.0/20, 10.0.32.0/20 (4,091 usable IPs each)
  # Private subnets are large because the VPC CNI gives every pod a VPC IP.
  public_subnet_cidrs  = [for i in range(local.az_count) : cidrsubnet(var.cidr_block, 8, i)]
  private_subnet_cidrs = [for i in range(local.az_count) : cidrsubnet(var.cidr_block, 4, i + 1)]
}

resource "aws_vpc" "this" {
  cidr_block = var.cidr_block

  # Both are required for interface endpoint private DNS: without them
  # ecr.<region>.amazonaws.com would still resolve to public IPs that the
  # private subnets can't reach.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = var.name })
}

# Take over the default security group and strip all its rules, so nothing
# that forgets to set a security group gets implicit allow-all access.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-default-deny" })
}

# ---------------------------------------------------------------------------
# Public tier: ingress only (future internet-facing ALB/NLB)
# ---------------------------------------------------------------------------

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = var.name })
}

resource "aws_subnet" "public" {
  count = local.az_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name                     = "${var.name}-public-${local.azs[count.index]}"
    Tier                     = "public"
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-public" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = local.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# Private tier: EKS nodes and control-plane ENIs. No default route at all.
# ---------------------------------------------------------------------------

resource "aws_subnet" "private" {
  count = local.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, {
    Name                              = "${var.name}-private-${local.azs[count.index]}"
    Tier                              = "private"
    "kubernetes.io/role/internal-elb" = "1"
  })
}

# One shared route table: with no NAT gateway there's no per-AZ next hop to
# differ on. It holds only the implicit local route plus the S3 prefix-list
# route added by the gateway endpoint below.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-private" })
}

resource "aws_route_table_association" "private" {
  count = local.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ---------------------------------------------------------------------------
# S3 gateway endpoint: free, route-table based. ECR stores image layers in S3,
# so pulls need it. The policy only allows reading ECR's layer bucket, so the
# endpoint can't be used to copy data into an arbitrary bucket.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "s3_endpoint" {
  statement {
    sid     = "AllowEcrImageLayerDownloads"
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = concat(
      ["arn:${data.aws_partition.current.partition}:s3:::prod-${local.region}-starport-layer-bucket/*"],
      var.s3_endpoint_extra_bucket_arns,
    )

    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  policy            = data.aws_iam_policy_document.s3_endpoint.json

  tags = merge(var.tags, { Name = "${var.name}-s3" })
}

# ---------------------------------------------------------------------------
# Interface endpoints (PrivateLink): one ENI per private subnet per service.
# ---------------------------------------------------------------------------

resource "aws_security_group" "endpoints" {
  name_prefix = "${var.name}-vpce-"
  description = "Interface VPC endpoints: HTTPS from inside the VPC only"
  vpc_id      = aws_vpc.this.id

  # No egress rules: endpoints only answer connections; they never start them.
  # Security groups are stateful, so replies don't need an egress rule.

  tags = merge(var.tags, { Name = "${var.name}-vpce" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  security_group_id = aws_security_group.endpoints.id
  description       = "HTTPS from any address in the VPC CIDR"
  cidr_ipv4         = var.cidr_block
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_endpoint" "interface" {
  for_each = var.interface_endpoints

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${local.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${var.name}-${each.key}" })
}

# ---------------------------------------------------------------------------
# Flow logs (optional): an audit trail of every flow, including the
# attempted-and-dropped egress that shows the cluster is isolated.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "flow_logs" {
  #checkov:skip=CKV_AWS_338:Lab environment: logs are kept for var.flow_logs_retention_days (default 30), not a year. Production would set 365+ for audit.
  count = var.enable_flow_logs ? 1 : 0

  name              = coalesce(var.flow_logs_log_group_name, "/aws/vpc/${var.name}/flow-logs")
  retention_in_days = var.flow_logs_retention_days
  kms_key_id        = var.flow_logs_kms_key_arn

  tags = var.tags
}

data "aws_iam_policy_document" "flow_logs_assume" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }

    # Confused-deputy protection: only flow logs in this account may assume it.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:ec2:${local.region}:${data.aws_caller_identity.current.account_id}:vpc-flow-log/*"]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name_prefix        = "${var.name}-flow-logs-"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume[0].json

  tags = var.tags
}

# Scoped to this one log group, instead of the logs:* on "*" in many examples.
data "aws_iam_policy_document" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    sid = "WriteToFlowLogGroup"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = [
      aws_cloudwatch_log_group.flow_logs[0].arn,
      "${aws_cloudwatch_log_group.flow_logs[0].arn}:*",
    ]
  }

  statement {
    sid       = "DescribeLogGroupsInRegion"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["arn:${data.aws_partition.current.partition}:logs:${local.region}:${data.aws_caller_identity.current.account_id}:log-group:*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name   = "write-flow-logs"
  role   = aws_iam_role.flow_logs[0].id
  policy = data.aws_iam_policy_document.flow_logs[0].json
}

resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id                   = aws_vpc.this.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs[0].arn
  iam_role_arn             = aws_iam_role.flow_logs[0].arn
  max_aggregation_interval = 60

  tags = merge(var.tags, { Name = var.name })
}
