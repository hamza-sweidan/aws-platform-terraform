# envs/dev

Composes the modules into the dev platform. This is a root module with remote
state in the bootstrap bucket (S3 native locking) and a committed
`.terraform.lock.hcl`.

```text
kms ──► vpc (flow logs) ──► bastion (optional)
 │        │                    │
 │        ▼                    ▼
 └──► iam ◄──► eks ◄──── api_client_security_group_ids
          (roles -> cluster -> access entries / IRSA)
ecr.tf: mirror repositories for offline images
```

## What the environment decides

| Concern | Where |
|---|---|
| Names | `"${project}-${environment}"` gives `aws-platform-dev` for everything |
| Tags | Provider `default_tags`: Project, Environment, Owner, ManagedBy=Terraform. Also passed as `node_tags`, because launch template tag specifications don't inherit default tags. |
| Endpoints | The 5 core EKS endpoints, plus `ssm`/`ssmmessages`/`ec2messages` only while `enable_bastion = true` |
| Log group names | Fixed in `locals` because the KMS key policy must name them before they exist |
| Admins | `cluster_admin_principal_arns` in `terraform.tfvars`, never committed |

## Usage

```bash
cd envs/dev
terraform -chdir=../../bootstrap output -raw backend_config > backend.hcl
cp terraform.tfvars.example terraform.tfvars   # set owner + your IAM ARN
terraform init -backend-config=backend.hcl
terraform plan -out=tfplan
terraform apply tfplan                          # ~15-20 min, mostly EKS
```

See the [root README](../../README.md) for verification, the offline demo and
teardown.

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

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| bastion | ../../modules/bastion | n/a |
| eks | ../../modules/eks | n/a |
| iam | ../../modules/iam | n/a |
| kms | ../../modules/kms | n/a |
| vpc | ../../modules/vpc | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_ecr_lifecycle_policy.mirror](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_lifecycle_policy) | resource |
| [aws_ecr_repository.mirror](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_repository) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| cluster\_admin\_principal\_arns | IAM users/roles that get cluster-admin via EKS access entries. Put your own IAM user ARN here (terraform.tfvars). | `list(string)` | n/a | yes |
| owner | Owner tag value, e.g. your GitHub handle or team. | `string` | n/a | yes |
| availability\_zones | Exactly which AZs to use. Pinned so the subnet layout never moves. | `list(string)` | <pre>[<br/>  "eu-central-1a",<br/>  "eu-central-1b"<br/>]</pre> | no |
| ecr\_repositories | Private ECR repositories to create for mirrored images. | `set(string)` | <pre>[<br/>  "mirror/nginx-unprivileged"<br/>]</pre> | no |
| enable\_bastion | Create the SSM bastion and its three SSM interface endpoints (~$0.08/h extra). Needed for kubectl access to the private API. | `bool` | `false` | no |
| enable\_flow\_logs | Send VPC flow logs to CloudWatch Logs. | `bool` | `true` | no |
| environment | Environment name, used in resource names and the Environment tag. | `string` | `"dev"` | no |
| kubernetes\_version | EKS Kubernetes minor version. | `string` | `"1.36"` | no |
| log\_retention\_days | Retention for control-plane and flow log groups. | `number` | `30` | no |
| node\_capacity\_type | ON\_DEMAND or SPOT. SPOT is ~60-70% cheaper for a lab that can tolerate interruptions. | `string` | `"ON_DEMAND"` | no |
| node\_desired\_size | Initial node count (one per AZ by default). | `number` | `2` | no |
| node\_instance\_types | Node instance types. | `list(string)` | <pre>[<br/>  "t3.medium"<br/>]</pre> | no |
| node\_max\_size | Maximum node count. | `number` | `3` | no |
| node\_min\_size | Minimum node count. | `number` | `1` | no |
| project | Project name, used in resource names and the Project tag. | `string` | `"aws-platform"` | no |
| region | AWS region for the environment. | `string` | `"eu-central-1"` | no |
| vpc\_cidr | VPC IPv4 CIDR. | `string` | `"10.0.0.0/16"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| addon\_versions | Resolved EKS add-on versions. |
| bastion\_instance\_id | SSM bastion instance ID, or null when enable\_bastion = false. |
| cluster\_arn | EKS cluster ARN (also the kubeconfig cluster entry name). |
| cluster\_endpoint | Private API endpoint (reachable only from inside the VPC). |
| cluster\_name | EKS cluster name. |
| cluster\_version | Kubernetes version. |
| ecr\_repository\_urls | Mirror repository URLs by name. |
| interface\_endpoints | Interface VPC endpoints by service. |
| kms\_key\_arn | Platform KMS key ARN. |
| kubeconfig\_commands | Point kubectl at the SSM tunnel while still verifying the API certificate against its real hostname. |
| private\_subnet\_ids | Private subnet IDs (nodes and control-plane ENIs). |
| region | AWS region. |
| ssm\_tunnel\_command | Run in its own terminal (bash) to forward localhost:8443 to the private API through the bastion. |
| vpc\_id | VPC ID. |
<!-- END_TF_DOCS -->
