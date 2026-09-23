# One-time setup for remote state: an S3 bucket that every other root module
# (envs/*) uses as its backend. Locking uses S3 native lock files
# (use_lockfile = true), so no DynamoDB table is needed.
#
# Also creates an optional monthly AWS Budget so a forgotten cluster can't
# silently burn through the account's credits.

data "aws_caller_identity" "current" {}

locals {
  # Bucket names are global across all AWS accounts, so the account ID and
  # region make the name unique and predictable without a random suffix.
  state_bucket_name = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}-${var.region}"
}

resource "aws_s3_bucket" "state" {
  #checkov:skip=CKV_AWS_18:Server access logging would need a second bucket for a single-user state bucket. CloudTrail management events already record who touched it.
  #checkov:skip=CKV_AWS_144:Cross-region replication doubles storage and needs a second bucket; versioning covers the realistic failure (a bad apply), not a regional S3 outage.
  #checkov:skip=CKV2_AWS_62:Nothing consumes S3 event notifications for state files.
  bucket = local.state_bucket_name

  # Deleting the state bucket orphans every resource it tracks.
  # Terraform refuses to plan its destruction while this is set.
  lifecycle {
    prevent_destroy = true
  }
}

# ACLs disabled: the bucket owner owns every object and access is governed
# only by IAM and the bucket policy.
resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Every apply writes a new object version, so a corrupted or wrongly
# applied state can be rolled back by restoring the previous version.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-KMS with the AWS managed key (aws/s3): no monthly key fee, and every
# decrypt is a KMS call visible in CloudTrail. The bucket key caches a
# data key per bucket to cut KMS request charges.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    # Every plan/apply also writes and deletes a .tflock object, which leaves
    # noncurrent versions behind. Expiring them keeps the bucket from growing.
    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

data "aws_iam_policy_document" "state" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state.json

  # Apply the public access block first so there's never a window where a
  # policy exists without it.
  depends_on = [aws_s3_bucket_public_access_block.state]
}

# Cost guardrail. The first two AWS Budgets without actions are free.
resource "aws_budgets_budget" "monthly" {
  count = var.budget_alert_email == null ? 0 : 1

  name         = "${var.project}-monthly"
  budget_type  = "COST"
  limit_amount = format("%.2f", var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Track gross usage. With credits included the net cost stays ~0 and the
  # alerts would never fire while the credits drain.
  cost_types {
    include_credit = false
    include_refund = false
  }

  dynamic "notification" {
    for_each = [50, 80, 100]

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.budget_alert_email]
    }
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}
