# A customer managed KMS key shared by the platform: EKS envelope encryption
# of Kubernetes Secrets, and the EKS control-plane and VPC flow log groups.
#
# Access model:
# - The key policy delegates to IAM (the account root statement), so IAM
#   roles such as the EKS cluster role get key access through identity
#   policies in modules/iam.
# - The CloudWatch Logs service is granted access directly, but only for the
#   exact log group ARNs passed in (encryption-context condition).

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region

  log_group_arns = [
    for n in var.cloudwatch_log_group_names :
    "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:${n}"
  ]
}

data "aws_iam_policy_document" "key" {
  #checkov:skip=CKV_AWS_109:KMS key policy. Resource "*" means "this key" and the root principal delegates to IAM (the AWS default key policy); without it the key becomes unmanageable.
  #checkov:skip=CKV_AWS_111:Same as CKV_AWS_109: a key policy can only ever apply to its own key.
  #checkov:skip=CKV_AWS_356:Same as CKV_AWS_109: "*" in a key policy can't be narrowed further.

  statement {
    sid       = "EnableIamPoliciesForThisAccount"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  dynamic "statement" {
    for_each = length(local.log_group_arns) > 0 ? [1] : []

    content {
      sid = "AllowCloudWatchLogsForNamedLogGroups"
      actions = [
        "kms:Encrypt*",
        "kms:Decrypt*",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:Describe*",
      ]
      resources = ["*"]

      principals {
        type        = "Service"
        identifiers = ["logs.${local.region}.amazonaws.com"]
      }

      condition {
        test     = "ArnEquals"
        variable = "kms:EncryptionContext:aws:logs:arn"
        values   = local.log_group_arns
      }
    }
  }
}

resource "aws_kms_key" "this" {
  description             = var.description
  enable_key_rotation     = true
  rotation_period_in_days = 365
  deletion_window_in_days = var.deletion_window_in_days
  policy                  = data.aws_iam_policy_document.key.json

  tags = merge(var.tags, { Name = var.name })
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.name}"
  target_key_id = aws_kms_key.this.key_id
}
