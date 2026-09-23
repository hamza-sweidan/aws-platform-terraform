# eks

A private Amazon EKS cluster designed to run with **no internet egress**.

## What makes it private

| Setting | Value | Effect |
|---|---|---|
| `endpoint_public_access` | `false` | The API server has no public endpoint. Its hostname resolves to ENIs in the private subnets. See [ADR 0003](../../docs/decisions/0003-private-only-api-endpoint.md). |
| `endpoint_private_access` | `true` | Nodes register through the in-VPC endpoint. AWS requires this for clusters without internet. |
| Node subnets | private only | No route to an IGW or NAT. Image pulls go to ECR over the VPC endpoints. |
| `api_client_security_group_ids` | e.g. bastion SG | Only listed security groups (plus the nodes) can open 443 to the API ENIs. |

## Other design choices

- **Managed add-ons, `bootstrap_self_managed_addons = false`.** vpc-cni,
  kube-proxy and coredns are EKS add-ons with versions resolved from
  `aws_eks_addon_version` (the EKS default for the chosen Kubernetes version,
  not "latest"). Terraform manages them through the EKS API, so it never
  needs network access to the private Kubernetes API.
  - The VPC CNI runs under its own **IRSA role** (see `modules/iam`) with
    **network policy enforcement** turned on (eBPF agent).
  - Ordering: `vpc-cni` and `kube-proxy` before the node group, because nodes
    stay NotReady without a CNI. `coredns` comes after, because it's a
    Deployment and needs nodes.
- **Access entries only**: `authentication_mode = "API"` and no implicit
  admin for the cluster creator.
- **Envelope encryption** of Secrets with the platform KMS key.
- **All five control-plane log types** go to a log group created before the
  cluster, with retention and KMS encryption.
- **`upgrade_policy = STANDARD`**: at end of standard support EKS upgrades
  the cluster, so it never drifts into extended support at 6x the hourly
  price.
- **Launch template hardening**: IMDSv2 required with **hop limit 1**, so
  containers without host networking can't reach instance metadata and
  borrow the node role. gp3 root volume, encrypted. No SSH key.
- **Node group** uses `create_before_destroy` and ignores `desired_size`
  after creation, leaving room for Cluster Autoscaler or Karpenter.

## Usage

```hcl
module "eks" {
  source = "../../modules/eks"

  cluster_name       = "aws-platform-dev"
  kubernetes_version = "1.36"
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnet_ids

  cluster_role_arn = module.iam.cluster_role_arn
  node_role_arn    = module.iam.node_role_arn
  vpc_cni_role_arn = module.iam.vpc_cni_role_arn
  kms_key_arn      = module.kms.key_arn

  api_client_security_group_ids = [module.bastion[0].security_group_id]
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
| [aws_cloudwatch_log_group.cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_eks_addon.coredns](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_addon) | resource |
| [aws_eks_addon.kube_proxy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_addon) | resource |
| [aws_eks_addon.vpc_cni](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_addon) | resource |
| [aws_eks_cluster.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_cluster) | resource |
| [aws_eks_node_group.default](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_node_group) | resource |
| [aws_launch_template.node](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/launch_template) | resource |
| [aws_security_group.cluster_api](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_vpc_security_group_ingress_rule.cluster_api](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_eks_addon_version.default](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/eks_addon_version) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| cluster\_name | Name of the EKS cluster. | `string` | n/a | yes |
| cluster\_role\_arn | IAM role assumed by the EKS control plane (modules/iam). | `string` | n/a | yes |
| kms\_key\_arn | KMS key for Kubernetes Secrets envelope encryption and the control-plane log group. | `string` | n/a | yes |
| node\_role\_arn | IAM role for worker nodes (modules/iam). | `string` | n/a | yes |
| subnet\_ids | Private subnets for the control-plane ENIs and the node group. Must span at least two AZs and have the required VPC endpoints. | `list(string)` | n/a | yes |
| vpc\_cni\_role\_arn | IRSA role for the vpc-cni add-on's aws-node service account (modules/iam). | `string` | n/a | yes |
| vpc\_id | VPC for the cluster security group. | `string` | n/a | yes |
| addon\_versions | Optional pinned versions per add-on (keys: vpc-cni, kube-proxy, coredns). Unset add-ons use the EKS default for kubernetes\_version. | `map(string)` | `{}` | no |
| api\_client\_security\_group\_ids | Security groups (for example the bastion's) allowed to reach the private API endpoint on 443. Nodes already have access through the EKS-managed cluster security group. | `list(string)` | `[]` | no |
| enable\_network\_policy | Enforce Kubernetes NetworkPolicy with the VPC CNI's eBPF network policy agent. | `bool` | `true` | no |
| enabled\_log\_types | Control-plane log types to send to CloudWatch Logs. | `list(string)` | <pre>[<br/>  "api",<br/>  "audit",<br/>  "authenticator",<br/>  "controllerManager",<br/>  "scheduler"<br/>]</pre> | no |
| kubernetes\_version | Kubernetes minor version. 1.36 is the EKS default in standard support until 2027-08. | `string` | `"1.36"` | no |
| log\_retention\_days | Retention for the control-plane log group. | `number` | `30` | no |
| node\_ami\_type | EKS-optimized AMI family for the managed node group. | `string` | `"AL2023_x86_64_STANDARD"` | no |
| node\_capacity\_type | ON\_DEMAND or SPOT. | `string` | `"ON_DEMAND"` | no |
| node\_desired\_size | Initial number of nodes. Ignored after creation so an autoscaler can own it. | `number` | `2` | no |
| node\_disk\_size\_gib | Root EBS volume size (gp3, encrypted) per node. | `number` | `20` | no |
| node\_instance\_types | Instance types for the node group. With SPOT, list several of the same size to improve capacity. | `list(string)` | <pre>[<br/>  "t3.medium"<br/>]</pre> | no |
| node\_max\_size | Maximum number of nodes. | `number` | `3` | no |
| node\_min\_size | Minimum number of nodes. | `number` | `1` | no |
| node\_tags | Tags for node EC2 instances and volumes. Provider default\_tags don't reach launch template tag\_specifications, so pass them here for cost allocation. | `map(string)` | `{}` | no |
| service\_ipv4\_cidr | CIDR for Kubernetes Service ClusterIPs. Must not overlap the VPC or anything it's peered with. | `string` | `"172.20.0.0/16"` | no |
| tags | Extra tags for EKS resources. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| addon\_versions | Resolved add-on versions. |
| api\_security\_group\_id | Additional security group controlling which in-VPC clients may reach the API. |
| cluster\_arn | ARN of the EKS cluster. |
| cluster\_certificate\_authority\_data | Base64-encoded cluster CA certificate. |
| cluster\_endpoint | Private API server endpoint URL. It resolves to private IPs and is reachable only from inside the VPC. |
| cluster\_endpoint\_host | API server hostname without scheme, for SSM port forwarding and kubectl --tls-server-name. |
| cluster\_name | Name of the EKS cluster. Referencing it creates a dependency on the cluster. |
| cluster\_security\_group\_id | EKS-managed cluster security group, shared by the control-plane ENIs and the managed nodes. |
| cluster\_version | Kubernetes version of the control plane. |
| log\_group\_name | CloudWatch log group receiving control-plane logs. |
| node\_group\_name | Name of the default managed node group. |
| oidc\_issuer\_url | OIDC issuer URL for IRSA. |
<!-- END_TF_DOCS -->
