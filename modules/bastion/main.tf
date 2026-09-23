# A small EC2 instance in a private subnet, used as an SSM Session Manager
# target. It has no SSH key, no public IP and no inbound rules. Its main job
# is to be the far end of an SSM port-forwarding tunnel to the private EKS
# API endpoint, so kubectl on your laptop can reach the cluster.

data "aws_ssm_parameter" "ami" {
  name = var.ami_ssm_parameter
}

data "aws_partition" "current" {}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = "${var.name}-ssm"
  description          = "SSM-managed bastion ${var.name}: Session Manager only"
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  max_session_duration = 3600

  tags = var.tags
}

# The AWS-documented minimum for an instance to register with Systems Manager
# and accept Session Manager sessions. The role gets no EKS or other API access.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name}-ssm"
  role = aws_iam_role.this.name

  tags = var.tags
}

resource "aws_security_group" "this" {
  name_prefix = "${var.name}-"
  description = "SSM bastion: no inbound, HTTPS out to the VPC only"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = var.name })

  lifecycle {
    create_before_destroy = true
  }
}

# No ingress rules at all. The SSM Agent dials out to the ssmmessages
# endpoint and sessions ride back over that connection.
resource "aws_vpc_security_group_egress_rule" "https_to_vpc" {
  security_group_id = aws_security_group.this.id
  description       = "HTTPS to SSM interface endpoints and the private EKS API"
  cidr_ipv4         = var.vpc_cidr_block
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_instance" "this" {
  ami                         = data.aws_ssm_parameter.ami.insecure_value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.this.id]
  iam_instance_profile        = aws_iam_instance_profile.this.name
  associate_public_ip_address = false
  ebs_optimized               = true
  monitoring                  = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = merge(var.tags, { Name = var.name })

  lifecycle {
    # A new AL2023 AMI is published every few weeks. Don't replace the
    # instance on every plan; recreate it deliberately (taint/replace) instead.
    ignore_changes = [ami]
  }
}
