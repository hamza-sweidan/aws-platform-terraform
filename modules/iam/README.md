# iam

Identity and authorization for the EKS platform.

| Identity | Assumed by | Permissions |
|---|---|---|
| Cluster role | `eks.amazonaws.com` | `AmazonEKSClusterPolicy` + custom inline policy with 4 KMS actions on the platform key only |
| Node role | `ec2.amazonaws.com` | `AmazonEKSWorkerNodePolicy` + `AmazonEC2ContainerRegistryPullOnly` |
| VPC CNI role (IRSA) | `kube-system/aws-node` via OIDC | `AmazonEKS_CNI_Policy` |
| Access entries | Your IAM user/role | `AmazonEKSClusterAdminPolicy`, cluster scope |

## Least-privilege choices

- **CNI permissions are off the node role.** `AmazonEKS_CNI_Policy` lets its
  holder create and attach ENIs and assign IPs. On the node role, any process
  that can reach instance metadata could use it. As an IRSA role, only the
  `aws-node` service account can assume it. The trust policy pins both `sub`
  (service account) and `aud` (`sts.amazonaws.com`). The node launch template
  in `modules/eks` also sets the IMDS hop limit to 1, so pods can't borrow
  the node role either.
- **`PullOnly` instead of `ReadOnly` for ECR.** Nodes can fetch images but
  can't list or describe every repository.
- **No SSM on nodes.** The bastion is the only Session Manager target.
- **Access entries, not `aws-auth`.** The cluster runs with
  `authentication_mode = "API"` and
  `bootstrap_cluster_creator_admin_permissions = false`. Admin access is an
  explicit, reviewable Terraform resource, not a side effect of whoever
  created the cluster. Access entries are managed through the EKS API, so a
  bad entry can be fixed with the AWS CLI without cluster access. A broken
  `aws-auth` ConfigMap could lock everyone out.

## Why this module references the eks module and vice versa

`modules/eks` needs the role ARNs, and this module needs the cluster name and
OIDC issuer for access entries and IRSA. Terraform plans at resource level,
so the real chain has no cycle:

```text
cluster role -> EKS cluster -> OIDC provider -> CNI role -> vpc-cni add-on
                            -> access entries
```

Role names use `var.name` (a plain string), never the cluster name.
Otherwise the role would depend on the cluster that depends on the role.

## Usage

```hcl
module "iam" {
  source = "../../modules/iam"

  name                         = "aws-platform-dev"
  cluster_name                 = module.eks.cluster_name
  cluster_oidc_issuer_url      = module.eks.oidc_issuer_url
  kms_key_arn                  = module.kms.key_arn
  cluster_admin_principal_arns = ["arn:aws:iam::111122223333:user/alice"]
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
| aws | >= 6.0, < 7.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_eks_access_entry.admin](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_access_entry) | resource |
| [aws_eks_access_policy_association.admin](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_access_policy_association) | resource |
| [aws_iam_openid_connect_provider.cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_openid_connect_provider) | resource |
| [aws_iam_role.cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.node](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.vpc_cni](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.cluster_kms](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.node](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.vpc_cni](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_policy_document.cluster_kms](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.ec2_assume](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.eks_assume](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.vpc_cni_assume](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| cluster\_admin\_principal\_arns | IAM users or roles that get cluster-admin through EKS access entries, e.g. arn:aws:iam::111122223333:user/alice. | `list(string)` | n/a | yes |
| cluster\_name | EKS cluster name for access entries. Pass module.eks.cluster\_name (not a literal) so access entries wait for the cluster. | `string` | n/a | yes |
| cluster\_oidc\_issuer\_url | The cluster's OIDC issuer URL (module.eks.oidc\_issuer\_url), used to create the IAM OIDC provider for IRSA. | `string` | n/a | yes |
| kms\_key\_arn | KMS key the EKS cluster role may use for secrets envelope encryption. | `string` | n/a | yes |
| name | Prefix for IAM role names, e.g. aws-platform-dev. Must be a plain string, not derived from the cluster, because the cluster needs these roles first. | `string` | n/a | yes |
| tags | Extra tags for IAM resources. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| cluster\_admin\_principal\_arns | Principals that were given cluster-admin access entries. |
| cluster\_role\_arn | ARN of the EKS cluster IAM role (returned once its policies are attached). |
| node\_role\_arn | ARN of the worker node IAM role (returned once its policies are attached). |
| node\_role\_name | Name of the worker node IAM role. |
| oidc\_provider\_arn | ARN of the IAM OIDC provider for IRSA. Reuse it for other service-account roles. |
| vpc\_cni\_role\_arn | ARN of the IRSA role for the VPC CNI (returned once its policy is attached). |
<!-- END_TF_DOCS -->
