# Runbook

Likely failures in a private, zero-egress EKS cluster, and how to diagnose
each. Commands assume bash, `CLUSTER=aws-platform-dev`, `REGION=eu-central-1`,
and (for kubectl) a running SSM tunnel (see the root README).

```bash
CLUSTER=aws-platform-dev REGION=eu-central-1
VPC_ID=$(terraform -chdir=envs/dev output -raw vpc_id)
```

---

## 1. Nodes don't join: node group fails with `NodeCreationFailure`

**Symptoms.** `terraform apply` sits on `aws_eks_node_group.default` for about
20 minutes, then fails with *"Instances failed to join the kubernetes
cluster"*. Or the nodes join but stay `NotReady`.

**Why it happens here.** With no NAT, every AWS API a booting node calls must
have an endpoint. If one is missing, the call just times out.

| Missing | What breaks |
|---|---|
| `ec2` | The EKS-optimized AMI can't look up its own private DNS name, so kubelet won't register. The VPC CNI can't attach ENIs or assign pod IPs. |
| `ecr.api` / `ecr.dkr` / S3 gateway | The `pause`, `aws-node` and `kube-proxy` images (all in ECR) can't be pulled. |
| `sts` | `aws-node` uses IRSA and can't get credentials. The CNI never starts and nodes stay `NotReady`. |

**Diagnose.**

```bash
# What EKS itself thinks is wrong
aws eks describe-nodegroup --region $REGION --cluster-name $CLUSTER \
  --nodegroup-name "$(aws eks list-nodegroups --region $REGION --cluster-name $CLUSTER --query 'nodegroups[0]' --output text)" \
  --query 'nodegroup.health.issues'

# Are all endpoints there, available, with private DNS on?
aws ec2 describe-vpc-endpoints --region $REGION --filters Name=vpc-id,Values=$VPC_ID \
  --query 'VpcEndpoints[].[ServiceName,VpcEndpointType,State,PrivateDnsEnabled]' --output table

# What the node saw while booting (nodeadm/kubelet errors, API timeouts)
aws ec2 get-console-output --region $REGION --latest --output text \
  --instance-id "$(aws ec2 describe-instances --region $REGION \
     --filters Name=tag:eks:cluster-name,Values=$CLUSTER Name=instance-state-name,Values=running \
     --query 'Reservations[0].Instances[0].InstanceId' --output text)" | tail -50

# Nodes joined but NotReady: is the CNI getting credentials?
kubectl -n kube-system logs ds/aws-node -c aws-node --tail=50 | grep -iE 'sts|webidentity|timeout|error'
kubectl -n kube-system get pod -l k8s-app=aws-node -o yaml | grep -A1 AWS_STS_REGIONAL_ENDPOINTS   # expect "regional"
```

From the bastion (`aws ssm start-session --target <id>`), check that AWS
names resolve to **private** IPs. If you see public IPs, private DNS is off,
or the VPC lacks `enableDnsSupport`/`enableDnsHostnames`:

```bash
getent hosts ec2.eu-central-1.amazonaws.com sts.eu-central-1.amazonaws.com api.ecr.eu-central-1.amazonaws.com
```

**Fix.** Add the missing service to `local.core_endpoints` in
`envs/dev/main.tf` and apply. A node group that failed creation doesn't
recover on its own: `terraform apply -replace=module.eks.aws_eks_node_group.default`.

---

## 2. `ImagePullBackOff` / `ErrImagePull`

**Diagnose.** The event message tells you which layer failed:

```bash
kubectl -n offline-demo get events --sort-by=.lastTimestamp | grep -iE 'pull|image'
kubectl -n offline-demo describe pod -l app.kubernetes.io/name=web | sed -n '/Events:/,$p'
```

| Message contains | Cause | Check / fix |
|---|---|---|
| `docker.io`, `quay.io`, `registry.k8s.io`, `ghcr.io` | Image isn't in ECR. There's no internet, by design. | Mirror it: `scripts/mirror-image.sh <image:tag>` and deploy the printed digest. |
| `dial tcp ...:443: i/o timeout` for `*.dkr.ecr.*` | `ecr.dkr` endpoint missing, private DNS off, or endpoint SG blocks 443 | `describe-vpc-endpoints` (above); SG ingress 443 from VPC CIDR |
| timeout for `prod-<region>-starport-layer-bucket.s3...` | Manifest fetched, **layers** blocked: S3 gateway endpoint missing or not associated with the private route table | `aws ec2 describe-route-tables --filters Name=vpc-id,Values=$VPC_ID --query 'RouteTables[].Routes[?DestinationPrefixListId]'` |
| `403 Forbidden` from S3 | S3 endpoint **policy** doesn't allow that bucket (e.g. a different region's layer bucket) | `aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=$VPC_ID Name=vpc-endpoint-type,Values=Gateway --query 'VpcEndpoints[].PolicyDocument'` |
| `no basic auth credentials` / `401` / `403` from ECR | Node role lacks `AmazonEC2ContainerRegistryPullOnly`, or `ecr.api` endpoint missing (the credential provider can't call `GetAuthorizationToken`) | `aws iam list-attached-role-policies --role-name aws-platform-dev-eks-node` |
| `manifest unknown` / `not found` | Wrong repo, tag, digest or region | `aws ecr describe-images --repository-name mirror/nginx-unprivileged --query 'imageDetails[].[imageDigest,imageTags]'` |
| `no match for platform in manifest` | Mirrored the wrong architecture | Re-run with `PLATFORM=linux/amd64` (AL2023 x86_64 nodes) |

From the bastion, `curl -s -o /dev/null -w '%{http_code}\n' https://<account>.dkr.ecr.eu-central-1.amazonaws.com/v2/`
returning `401` means the ECR endpoint is reachable; the 401 just asks for
credentials. S3 layer downloads can't be tested from the bastion, because
its security group only allows the VPC CIDR.

---

## 3. Access entry misconfiguration: `Unauthorized` or `Forbidden`

**Tell them apart.**

- `error: You must be logged in to the server (Unauthorized)`: **authentication**.
  EKS found no access entry for the IAM principal that signed the token.
- `Error from server (Forbidden): ... User "arn:aws:iam::...:user/x" cannot list resource ...`:
  **authorization**. The entry exists but has no policy association, or a
  namespace-scoped one.

**Diagnose.**

```bash
# 1. Which principal is kubectl actually using? (AWS_PROFILE matters)
aws sts get-caller-identity --query Arn --output text

# 2. What does the cluster accept?
aws eks describe-cluster --region $REGION --name $CLUSTER --query 'cluster.accessConfig'   # expect API
aws eks list-access-entries --region $REGION --cluster-name $CLUSTER
aws eks list-associated-access-policies --region $REGION --cluster-name $CLUSTER \
  --principal-arn arn:aws:iam::<account>:user/<you>

# 3. What the authenticator logged (control-plane logs are enabled)
aws logs start-query --region $REGION --log-group-name /aws/eks/$CLUSTER/cluster \
  --start-time $(( $(date +%s) - 3600 )) --end-time $(date +%s) \
  --query-string 'fields @timestamp, @message | filter @logStream like /authenticator/ | filter @message like /denied|not found|unknown/ | sort @timestamp desc | limit 20'
# then: aws logs get-query-results --query-id <id>
```

**Common causes.**

| Cause | Fix |
|---|---|
| Entry created for an **assumed-role** ARN (`arn:aws:sts::...:assumed-role/Name/session`) | Access entries take the **IAM role** ARN: `arn:aws:iam::<acct>:role/Name` |
| IAM Identity Center (SSO) role with its path | Use `arn:aws:iam::<acct>:role/AWSReservedSSO_...`, **without** `aws-reserved/sso.amazonaws.com/` |
| Different AWS profile than the one in `cluster_admin_principal_arns` | Export the right `AWS_PROFILE`, or add that principal |
| Expecting the cluster creator to be admin | Not in this design: `bootstrap_cluster_creator_admin_permissions = false`. Admins must be listed. |

**Fix.** Update `cluster_admin_principal_arns` and apply. Because access
entries live in the **EKS API** (not in an in-cluster ConfigMap), you can
always recover with the AWS CLI, even with zero working kubectl access:

```bash
aws eks create-access-entry --region $REGION --cluster-name $CLUSTER --principal-arn <arn>
aws eks associate-access-policy --region $REGION --cluster-name $CLUSTER --principal-arn <arn> \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy --access-scope type=cluster
```

(Then `terraform import` the entries or remove them before the next apply, so
Terraform doesn't fight you.)

---

## 4. kubectl can't reach the API through the SSM tunnel

| Symptom | Cause | Fix |
|---|---|---|
| `SessionManagerPlugin is not found` | Plugin not installed on the laptop | Install the AWS Session Manager plugin |
| `TargetNotConnected` | SSM Agent on the bastion isn't registered | `aws ssm describe-instance-information --region $REGION`; check the `ssm`/`ssmmessages`/`ec2messages` endpoints exist (only with `enable_bastion = true`) |
| `dial tcp 127.0.0.1:8443: connect: connection refused` | Tunnel isn't running | Start `terraform -chdir=envs/dev output -raw ssm_tunnel_command` in its own terminal |
| Tunnel is up but kubectl hangs, then times out | Bastion SG not allowed on the API SG | Check `module.eks.aws_vpc_security_group_ingress_rule.cluster_api` exists |
| `x509: certificate is valid for ..., not 127.0.0.1` | kubeconfig lacks `tls-server-name` | Re-run `kubeconfig_commands` output |

---

## 5. Terraform: state lock left behind

`Error acquiring the state lock` after a crashed or cancelled run. The lock is
the `envs/dev/terraform.tfstate.tflock` object in the state bucket. Confirm
nobody else is running Terraform, then run `terraform force-unlock <LOCK_ID>`
with the ID from the error message.

---

## 6. Pull request plan (CI) fails to authenticate

The `terraform-plan` workflow's AWS job assumes `aws-platform-github-plan`
through GitHub OIDC ([ADR 0009](decisions/0009-pull-request-plans-with-oidc.md)).

| Error in the job log | Cause | Fix |
|---|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | The token's subject doesn't match the trust policy: the workflow didn't run for a `pull_request` of this repository (a push, a manual run, a fork, or a renamed repository), or the repository IDs are wrong. | Check `github_repository` and `github_repository_ids` in `bootstrap/terraform.tfvars` against `gh api repos/OWNER/NAME/actions/oidc/customization/sub`, and the trigger. The role trusts only `repo:<owner>@<owner-id>/<repo>@<repo-id>:pull_request`. |
| `No OpenIDConnect provider found in your account` | `bootstrap` was applied without `github_repository`. | Set it and apply `bootstrap`. |
| `Credentials could not be loaded` / `id-token` errors | The job lacks `permissions: id-token: write`. | Keep the job-level permissions block. |
| `AccessDenied` on `s3:GetObject` for the state key | The `AWS_STATE_BUCKET` secret names a different bucket than the one the Deny statement exempts. | `terraform -chdir=bootstrap output -raw state_bucket_name` and update the secret. |
