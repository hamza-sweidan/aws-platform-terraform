# kms

One customer managed KMS key for the platform, used for:

- **EKS envelope encryption** of Kubernetes `Secret` objects in etcd. EKS
  already encrypts with an AWS owned key by default. A customer managed key
  adds a key you control, can disable, and can audit per use in CloudTrail.
- **CloudWatch log groups**: the EKS control-plane logs and VPC flow logs.

Automatic rotation is on, yearly. Old key material stays available for
decryption, so rotation never breaks existing data.

## Key policy design

| Statement | Grants | Why |
|---|---|---|
| `EnableIamPoliciesForThisAccount` | `kms:*` to the account root | The AWS default. It lets IAM policies grant key use, for example the EKS cluster role in `modules/iam`. Without it, only the key policy could ever grant access and a mistake could lock the key. |
| `AllowCloudWatchLogsForNamedLogGroups` | Encrypt/Decrypt/GenerateDataKey to `logs.<region>.amazonaws.com` | Restricted with `kms:EncryptionContext:aws:logs:arn` to the exact log group ARNs passed in, not every log group in the account. |

Cost: $1/month per key (prorated hourly) plus $0.03 per 10,000 requests.

## Usage

```hcl
module "kms" {
  source = "../../modules/kms"

  name = "aws-platform-dev"
  cloudwatch_log_group_names = [
    "/aws/eks/aws-platform-dev/cluster",
    "/aws/vpc/aws-platform-dev/flow-logs",
  ]
}
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.9, < 2.0 |
| aws | >= 6.0, < 7.0 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | 6.66.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_kms_alias.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.key](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| name | Name for the key alias (alias/<name>) and tags. | `string` | n/a | yes |
| cloudwatch\_log\_group\_names | Exact CloudWatch log group names allowed to use this key. CloudWatch Logs gets no access to any other log group. | `list(string)` | `[]` | no |
| deletion\_window\_in\_days | Waiting period before a scheduled key deletion completes. Anything encrypted with the key is unrecoverable once it's gone. | `number` | `7` | no |
| description | Human-readable key description shown in the KMS console. | `string` | `"Platform key: EKS secrets envelope encryption and CloudWatch log groups"` | no |
| tags | Extra tags for the key. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| alias\_name | Alias of the KMS key (alias/<name>). |
| key\_arn | ARN of the KMS key. |
| key\_id | ID of the KMS key. |
<!-- END_TF_DOCS -->
