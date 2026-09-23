# Offline unit tests with a mocked AWS provider (no credentials needed).

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }
  # The real provider still validates policy JSON, so the mock must be valid.
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  owner = "test-owner"
}

run "state_bucket_is_locked_down" {
  command = plan

  assert {
    condition     = aws_s3_bucket.state.bucket == "aws-platform-tfstate-111122223333-eu-central-1"
    error_message = "The bucket name must be <project>-tfstate-<account>-<region>."
  }

  assert {
    condition = (
      aws_s3_bucket_public_access_block.state.block_public_acls &&
      aws_s3_bucket_public_access_block.state.block_public_policy &&
      aws_s3_bucket_public_access_block.state.ignore_public_acls &&
      aws_s3_bucket_public_access_block.state.restrict_public_buckets
    )
    error_message = "All four public access blocks must be on."
  }

  assert {
    condition     = aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled"
    error_message = "Versioning is the undo button for a bad apply."
  }
}

run "no_ci_identity_by_default" {
  command = plan

  # Explicit, because a local terraform.tfvars (gitignored) may set it.
  variables {
    github_repository = null
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 0 && length(aws_iam_role.github_plan) == 0
    error_message = "No OIDC provider or role unless github_repository is set."
  }
}

run "ci_role_trusts_only_this_repos_pull_requests" {
  command = apply

  variables {
    github_repository = "hamza-sweidan/aws-platform-terraform"
  }

  assert {
    condition = anytrue([
      for c in data.aws_iam_policy_document.github_plan_assume[0].statement[0].condition :
      c.variable == "token.actions.githubusercontent.com:sub" &&
      c.test == "StringEquals" &&
      toset(c.values) == toset(["repo:hamza-sweidan/aws-platform-terraform:pull_request"])
    ])
    error_message = "The role must trust exactly this repository's pull_request tokens (StringEquals, no wildcards)."
  }

  assert {
    condition = anytrue([
      for c in data.aws_iam_policy_document.github_plan_assume[0].statement[0].condition :
      c.variable == "token.actions.githubusercontent.com:aud" && toset(c.values) == toset(["sts.amazonaws.com"])
    ])
    error_message = "The token audience must be sts.amazonaws.com."
  }

  assert {
    condition     = aws_iam_role_policy_attachment.github_plan_read_only[0].policy_arn == "arn:aws:iam::aws:policy/ReadOnlyAccess"
    error_message = "The plan role is read-only."
  }

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.github_plan_limits[0].statement :
      s.effect == "Deny" && contains(s.actions, "s3:GetObject") &&
      toset(s.not_resources) == toset(["${aws_s3_bucket.state.arn}/*"])
    ])
    error_message = "Object reads outside the state bucket must be explicitly denied."
  }
}

run "rejects_malformed_repository" {
  command = plan

  variables {
    github_repository = "https://github.com/hamza-sweidan/aws-platform-terraform"
  }

  expect_failures = [var.github_repository]
}
