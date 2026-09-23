# bootstrap

Creates the S3 bucket that holds Terraform state for every environment. Run it
once per AWS account. It is the only configuration in this repo with local
state, because it creates the backend everything else uses.

## What it creates

| Resource | Why |
|---|---|
| S3 bucket `<project>-tfstate-<account-id>-<region>` | Remote state. Account ID and region keep the global name unique with no random suffix. |
| Versioning | Every apply creates a new object version, so a bad apply can be rolled back. |
| SSE-KMS (AWS managed `aws/s3` key) + bucket key | Encryption at rest, KMS audit trail in CloudTrail, no $1/month key fee. |
| Public access block + `BucketOwnerEnforced` | No public access and no ACLs. Access is IAM and bucket policy only. |
| Bucket policy `DenyInsecureTransport` | Rejects any request that isn't over TLS. |
| Lifecycle rule | Expires old versions (including leftover `.tflock` versions) and aborts stuck multipart uploads. |
| `prevent_destroy` | `terraform destroy` fails instead of orphaning every environment's state. |
| AWS Budget (optional) | Emails at 50/80/100% actual and 100% forecast spend. Tracks gross cost, so credits don't hide it. |
| GitHub OIDC provider + `aws-platform-github-plan` role (optional, `github_repository`) | Read-only role for pull request plans. Trusts only `repo:<owner>/<repo>:pull_request` tokens; `ReadOnlyAccess` with explicit Denies on object reads outside the state bucket and on state writes. See [ADR 0009](../docs/decisions/0009-pull-request-plans-with-oidc.md). |

Locking uses **S3 native lock files** (`use_lockfile = true` in the consumers'
backend block). See [ADR 0002](../docs/decisions/0002-s3-native-state-locking.md).

## Usage

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars   # set owner, budget email
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# Hand the bucket name to the environment without committing it
terraform output -raw backend_config > ../envs/dev/backend.hcl
```

Keep `bootstrap/terraform.tfstate` safe; it's gitignored. If it's lost, the
bucket can be re-adopted with `terraform import aws_s3_bucket.state <bucket>`
and the same for the other resources.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | ~> 1.16.0 |
| aws | ~> 6.66 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | ~> 6.66 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_budgets_budget.monthly](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/budgets_budget) | resource |
| [aws_iam_openid_connect_provider.github](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_openid_connect_provider) | resource |
| [aws_iam_role.github_plan](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.github_plan_limits](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.github_plan_read_only](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_s3_bucket.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_ownership_controls.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.github_plan_assume](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.github_plan_limits](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| owner | Value for the Owner tag, e.g. your GitHub handle. | `string` | n/a | yes |
| budget\_alert\_email | Email address for budget alerts. Leave null to skip creating the budget. | `string` | `null` | no |
| github\_repository | GitHub repository (owner/name) whose pull\_request workflows may assume the read-only plan role. Leave null to create no OIDC provider or role. | `string` | `null` | no |
| monthly\_budget\_usd | Monthly AWS cost budget in USD. Alerts fire at 50/80/100% actual and 100% forecast. | `number` | `120` | no |
| noncurrent\_version\_retention\_days | Days to keep old state versions before S3 deletes them. Old versions are your undo button for a bad apply. | `number` | `90` | no |
| project | Short project name. Used in the bucket name and the Project tag. | `string` | `"aws-platform"` | no |
| region | AWS region for the state bucket. Use the same region as the environments. | `string` | `"eu-central-1"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| backend\_config | Partial backend config for envs/*. Write it with: terraform output -raw backend\_config > ../envs/dev/backend.hcl |
| budget\_name | Name of the monthly cost budget, or null if no alert email was given. |
| github\_plan\_role\_arn | Role for terraform plan in GitHub Actions (AWS\_PLAN\_ROLE\_ARN secret), or null when github\_repository isn't set. |
| region | Region of the state bucket. |
| state\_bucket\_arn | ARN of the state bucket, for IAM policies that grant state access. |
| state\_bucket\_name | Name of the S3 bucket that stores Terraform state. |
<!-- END_TF_DOCS -->
