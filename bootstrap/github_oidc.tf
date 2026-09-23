# Read-only identity for `terraform plan` on pull requests
# (.github/workflows/terraform-plan.yml). GitHub's OIDC token for the job is
# exchanged for 1-hour AWS credentials, so no access key is ever stored in
# GitHub. Off until var.github_repository is set.

locals {
  github_oidc_enabled = var.github_repository != null

  # GitHub's immutable subject: repo:OWNER@OWNER_ID/NAME@REPO_ID:pull_request.
  # Names can be taken over after a rename or deletion; the IDs can't, so a
  # new repository that reuses this name presents a different subject.
  github_plan_subject = local.github_oidc_enabled ? format(
    "repo:%s@%d/%s@%d:pull_request",
    split("/", var.github_repository)[0], var.github_repository_ids.owner,
    split("/", var.github_repository)[1], var.github_repository_ids.repository,
  ) : null
}

# One per account per issuer URL. AWS validates GitHub's certificate chain
# itself, so no thumbprint is needed.
resource "aws_iam_openid_connect_provider" "github" {
  count = local.github_oidc_enabled ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "github_plan_assume" {
  count = local.github_oidc_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github[0].arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only pull_request runs of this one repository. A push to main, a manual
    # dispatch or another repository gets a different subject and is refused.
    # GitHub doesn't issue OIDC tokens to pull requests from forks.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.github_plan_subject]
    }
  }
}

resource "aws_iam_role" "github_plan" {
  count = local.github_oidc_enabled ? 1 : 0

  name                 = "${var.project}-github-plan"
  description          = "terraform plan from GitHub Actions pull requests in ${var.github_repository} (read-only)"
  assume_role_policy   = data.aws_iam_policy_document.github_plan_assume[0].json
  max_session_duration = 3600
}

# A plan refreshes every resource in state, across EC2, EKS, IAM, KMS, ECR and
# CloudWatch, so a hand-written read policy would need constant upkeep.
# ReadOnlyAccess is the standard base; the inline policy below takes away
# the part a plan doesn't need.
resource "aws_iam_role_policy_attachment" "github_plan_read_only" {
  count = local.github_oidc_enabled ? 1 : 0

  role       = aws_iam_role.github_plan[0].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "github_plan_limits" {
  count = local.github_oidc_enabled ? 1 : 0

  # ReadOnlyAccess can read every S3 object in the account. A plan only reads
  # state files; an explicit Deny wins over any Allow.
  statement {
    sid           = "DenyObjectReadsOutsideTheStateBucket"
    effect        = "Deny"
    actions       = ["s3:GetObject", "s3:GetObjectVersion"]
    not_resources = ["${aws_s3_bucket.state.arn}/*"]
  }

  # Plans run with -lock=false, so the role never writes state or lock files.
  # Stated explicitly, so "CI can't touch state" doesn't depend on what the
  # managed policy happens to include.
  statement {
    sid       = "DenyStateWrites"
    effect    = "Deny"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }
}

resource "aws_iam_role_policy" "github_plan_limits" {
  count = local.github_oidc_enabled ? 1 : 0

  name   = "plan-limits"
  role   = aws_iam_role.github_plan[0].id
  policy = data.aws_iam_policy_document.github_plan_limits[0].json
}
