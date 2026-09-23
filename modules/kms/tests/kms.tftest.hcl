# Offline unit tests with a mocked AWS provider (no credentials needed).

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
  # The real provider still validates policy JSON, so the mock must be valid.
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  name = "test"
}

run "key_rotates_and_has_an_alias" {
  command = plan

  assert {
    condition     = aws_kms_key.this.enable_key_rotation && aws_kms_key.this.deletion_window_in_days == 7
    error_message = "Rotation must be on, with the shortest deletion window by default."
  }

  assert {
    condition     = aws_kms_alias.this.name == "alias/test"
    error_message = "The alias must be alias/<name>."
  }
}

run "no_log_group_access_unless_named" {
  command = plan

  assert {
    condition     = length(data.aws_iam_policy_document.key.statement) == 1
    error_message = "Without log group names, CloudWatch Logs gets no statement at all."
  }
}

run "log_group_access_is_scoped_to_exact_arns" {
  command = plan

  variables {
    cloudwatch_log_group_names = ["/aws/eks/test/cluster"]
  }

  assert {
    condition = anytrue(flatten([
      for s in data.aws_iam_policy_document.key.statement : [
        for c in s.condition :
        c.variable == "kms:EncryptionContext:aws:logs:arn" &&
        toset(c.values) == toset(["arn:aws:logs:eu-central-1:111122223333:log-group:/aws/eks/test/cluster"])
      ]
    ]))
    error_message = "CloudWatch Logs may use the key only for the named log group ARNs."
  }
}

run "rejects_reserved_alias_prefix" {
  command = plan

  variables {
    name = "aws/test"
  }

  expect_failures = [var.name]
}
