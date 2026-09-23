# 0001. No NAT gateway: private subnets have zero internet egress

- **Status:** Accepted
- **Date:** 2026-09-23

## Context

EKS worker nodes need to reach a handful of AWS APIs (ECR, EC2, STS, CloudWatch
Logs) and pull container images. The usual answer is a NAT gateway per AZ,
which gives every node and pod unrestricted outbound internet access.

That access is also an attack path: data exfiltration, command-and-control
callbacks, and pulling unreviewed images or packages at runtime. It also
doesn't match the air-gapped on-prem environments this design mirrors, where
there is no internet to fall back on.

## Decision

No NAT gateway. The private route table has only the local route and the S3
gateway endpoint's prefix list. Everything the cluster needs goes through VPC
endpoints:

- Interface endpoints: `ecr.api`, `ecr.dkr`, `ec2`, `sts`, `logs` (and `ssm`,
  `ssmmessages`, `ec2messages` while the bastion exists).
- S3 gateway endpoint, whose policy only allows `s3:GetObject` on ECR's layer
  bucket, so it can't be used to write data out.
- Images are mirrored into private ECR ahead of time (`scripts/mirror-image.sh`).

## Consequences

**Good**
- No path to the internet from the private subnets; this is enforced by routing, not policy.
- Supply chain: the cluster can only run images someone deliberately mirrored.
- Endpoint data processing is $0.01/GB vs $0.052/GB through NAT (eu-central-1).

**Costs and limits**
- Hourly cost is about the same, not lower: 5 endpoints × 2 AZs × $0.012 =
  $0.12/h, vs 2 NAT gateways × $0.052 = $0.104/h. This decision is about
  security, not saving money.
- Every new AWS dependency needs an endpoint first. For example:
  `elasticloadbalancing` for the AWS Load Balancer Controller, `autoscaling`
  for Cluster Autoscaler, `eks-auth` for Pod Identity.
- Some services have no endpoint at all. The ALB controller can't use ACM
  certificate discovery, and AWS Marketplace metered containers won't run.
- ECR pull-through cache needs internet on the first pull, so images are mirrored explicitly instead.

## Alternatives considered

| Option | Why not |
|---|---|
| NAT gateway | Unrestricted egress; the problem this avoids. |
| NAT + AWS Network Firewall (domain allowlist) | $0.395/h per firewall endpoint on top of NAT. Right for production egress control, too costly for this lab. |
| NAT + egress-restricted security groups | Security groups can't filter by domain, and AWS service IPs change. |
| Squid/HTTP proxy | Another fleet to run and patch, and it still needs NAT or an IGW itself. |
