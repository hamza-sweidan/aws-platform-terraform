# vpc

A two-tier VPC built for a private EKS cluster with **zero internet egress**.

- **Private subnets** (`/20` per AZ) hold the EKS nodes and control-plane ENIs.
  Their route table has **no default route**. The only destinations beyond the
  VPC are:
  - the **S3 gateway endpoint** (free), limited by its policy to ECR's image
    layer bucket, and
  - **interface endpoints** (PrivateLink) for the AWS APIs the cluster needs.
- **Public subnets** (`/24` per AZ) exist only so a future internet-facing
  load balancer has somewhere to live. They never auto-assign public IPs.
- **No NAT gateway.** See [ADR 0001](../../docs/decisions/0001-no-nat-gateway.md).
- The **default security group is emptied**, so an ENI created without a
  security group gets deny-all, not allow-all.
- **Flow logs** (optional) go to a KMS-encrypted CloudWatch log group, written by
  a role scoped to that one group, with confused-deputy conditions.

## Interface endpoints

Default set, from the AWS doc
[Deploy private clusters with limited internet access](https://docs.aws.amazon.com/eks/latest/userguide/private-clusters.html):

| Endpoint | Why the cluster needs it |
|---|---|
| `ecr.api` | Kubelet's credential provider calls `ecr:GetAuthorizationToken`. |
| `ecr.dkr` | Registry API: image manifests (`docker pull` protocol). |
| `s3` (gateway) | ECR stores the actual layers in S3 (`prod-<region>-starport-layer-bucket`). |
| `ec2` | The EKS-optimized AMI calls EC2 to set the node's DNS name. The VPC CNI calls EC2 to attach ENIs and assign pod IPs. |
| `sts` | IRSA: the VPC CNI's `aws-node` pods call `AssumeRoleWithWebIdentity` on the regional STS endpoint. |
| `logs` | Node and pod log shipping to CloudWatch Logs. |

The caller can append more, for example `ssm`, `ssmmessages` and `ec2messages`
when the bastion is enabled.

## Usage

```hcl
module "vpc" {
  source = "../../modules/vpc"

  name                = "aws-platform-dev"
  cidr_block          = "10.0.0.0/16"
  availability_zones  = ["eu-central-1a", "eu-central-1b"]
  interface_endpoints = ["ecr.api", "ecr.dkr", "ec2", "sts", "logs"]

  enable_flow_logs         = true
  flow_logs_log_group_name = "/aws/vpc/aws-platform-dev/flow-logs"
  flow_logs_kms_key_arn    = module.kms.key_arn
}
```

`private_subnet_ids` depends on the endpoints (an output `depends_on`), so
anything built on those subnets waits until the endpoints exist.

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
| [aws_cloudwatch_log_group.flow_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_default_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/default_security_group) | resource |
| [aws_flow_log.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/flow_log) | resource |
| [aws_iam_role.flow_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.flow_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_internet_gateway.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/internet_gateway) | resource |
| [aws_route.public_internet](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route) | resource |
| [aws_route_table.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table_association.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_route_table_association.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_security_group.endpoints](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_subnet.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_subnet.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_vpc.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc) | resource |
| [aws_vpc_endpoint.interface](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint) | resource |
| [aws_vpc_endpoint.s3](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint) | resource |
| [aws_vpc_security_group_ingress_rule.endpoints_https](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_availability_zones.selected](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/availability_zones) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.flow_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.flow_logs_assume](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.s3_endpoint](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| availability\_zones | Availability Zone names to create one public and one private subnet in, e.g. ["eu-central-1a", "eu-central-1b"]. Explicit so the layout never shifts when AWS adds a zone. EKS needs at least two. | `list(string)` | n/a | yes |
| name | Name prefix for every resource in the module, e.g. aws-platform-dev. | `string` | n/a | yes |
| cidr\_block | IPv4 CIDR for the VPC. Private subnets get /20s carved from it (pods take VPC IPs with the VPC CNI), public subnets /24s. | `string` | `"10.0.0.0/16"` | no |
| enable\_flow\_logs | Send VPC flow logs (all traffic) to CloudWatch Logs. | `bool` | `false` | no |
| flow\_logs\_kms\_key\_arn | KMS key ARN to encrypt the flow log group. The key policy must allow the CloudWatch Logs service. | `string` | `null` | no |
| flow\_logs\_log\_group\_name | CloudWatch log group name for flow logs. Passed in so the caller can also reference it in a KMS key policy. | `string` | `null` | no |
| flow\_logs\_retention\_days | Retention for the flow log group. | `number` | `30` | no |
| interface\_endpoints | AWS service short names to create interface endpoints for, e.g. ecr.api. Each becomes com.amazonaws.<region>.<name> in every private subnet. | `set(string)` | <pre>[<br/>  "ecr.api",<br/>  "ecr.dkr",<br/>  "ec2",<br/>  "sts",<br/>  "logs"<br/>]</pre> | no |
| s3\_endpoint\_extra\_bucket\_arns | Object ARNs (arn:aws:s3:::bucket/*) that workloads may read through the S3 gateway endpoint, in addition to the ECR layer bucket. | `list(string)` | `[]` | no |
| tags | Extra tags for every resource. Provider default\_tags already cover Project/Environment/Owner/ManagedBy. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| azs | Availability Zones the subnets were created in. |
| endpoint\_security\_group\_id | Security group attached to all interface endpoints. |
| flow\_log\_group\_name | CloudWatch log group receiving VPC flow logs, or null when disabled. |
| interface\_endpoint\_ids | Map of service short name to interface endpoint ID. |
| private\_route\_table\_id | ID of the shared private route table. |
| private\_subnet\_ids | IDs of the private subnets. Only returned once the S3 and interface endpoints exist (see depends\_on). |
| public\_subnet\_ids | IDs of the public subnets (for internet-facing load balancers only). |
| s3\_gateway\_endpoint\_id | ID of the S3 gateway endpoint. |
| vpc\_cidr\_block | IPv4 CIDR of the VPC. |
| vpc\_id | ID of the VPC. |
<!-- END_TF_DOCS -->
