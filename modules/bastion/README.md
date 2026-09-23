# bastion

An optional (`enable_bastion`, default `false`) SSM Session Manager host in a
private subnet. Its purpose is to reach the **private-only EKS API** from your
laptop without SSH, a public IP, or a VPN.

| Property | Value |
|---|---|
| Inbound rules | **None** |
| Outbound rules | TCP 443 to the VPC CIDR only (SSM endpoints + EKS API ENIs) |
| Public IP / SSH key | None / none |
| IAM | `AmazonSSMManagedInstanceCore` only. No EKS or other API permissions. |
| IMDS | v2 required, hop limit 1 |
| Disk | gp3, encrypted |
| AMI | Latest Amazon Linux 2023 from the public SSM parameter. `ignore_changes` stops constant replacement. |

The caller must also create the `ssm`, `ssmmessages` and `ec2messages`
interface endpoints. `envs/dev` adds them to the VPC module when
`enable_bastion = true`. Since SSM Agent 3.3.40.0, the agent prefers
`ssmmessages` over `ec2messages`. The latter is kept because AWS still lists
it for private instances.

See [ADR 0004](../../docs/decisions/0004-ssm-over-ssh.md) for why it's SSM, not SSH.

## How it's used: kubectl from your laptop over an SSM tunnel

The bastion doesn't need kubectl installed, which matters because it can't
download anything. It only forwards a TCP port:

```bash
# Terminal 1: laptop:8443 -> bastion -> EKS private endpoint:443
aws ssm start-session --target <instance_id> \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["<cluster_endpoint_host>"],"portNumber":["443"],"localPortNumber":["8443"]}'

# Terminal 2: point kubectl at the tunnel, but keep verifying the real cert name
aws eks update-kubeconfig --name <cluster> --alias <cluster>
kubectl config set-cluster <cluster_arn> \
  --server=https://127.0.0.1:8443 --tls-server-name=<cluster_endpoint_host>
kubectl get nodes
```

Authentication is still your own IAM identity (`aws eks get-token`, signed
locally) checked against your EKS access entry. The bastion's role has no
Kubernetes access.

## Usage

```hcl
module "bastion" {
  source = "../../modules/bastion"
  count  = var.enable_bastion ? 1 : 0

  name           = "aws-platform-dev-bastion"
  vpc_id         = module.vpc.vpc_id
  vpc_cidr_block = module.vpc.vpc_cidr_block
  subnet_id      = module.vpc.private_subnet_ids[0]
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
| [aws_iam_instance_profile.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_instance_profile) | resource |
| [aws_iam_role.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.ssm_core](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_instance.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance) | resource |
| [aws_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_vpc_security_group_egress_rule.https_to_vpc](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_iam_policy_document.assume](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_ssm_parameter.ami](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ssm_parameter) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| name | Name for the instance, role and security group. | `string` | n/a | yes |
| subnet\_id | Private subnet for the instance. It must have the ssm, ssmmessages and ec2messages interface endpoints. | `string` | n/a | yes |
| vpc\_cidr\_block | VPC CIDR. Egress is limited to HTTPS inside it (the SSM endpoints and the EKS API). | `string` | n/a | yes |
| vpc\_id | VPC to place the bastion in. | `string` | n/a | yes |
| ami\_ssm\_parameter | Public SSM parameter holding the AMI ID. The default tracks the latest Amazon Linux 2023, which ships with the SSM Agent. | `string` | `"/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"` | no |
| instance\_type | Instance type. The AMI is x86\_64, so use an x86 type. | `string` | `"t3.micro"` | no |
| tags | Extra tags. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| instance\_id | Instance ID, the target for `aws ssm start-session`. |
| private\_ip | Private IP of the bastion. |
| role\_arn | ARN of the bastion instance role. |
| security\_group\_id | Bastion security group. Allow it in the EKS API security group. |
<!-- END_TF_DOCS -->
