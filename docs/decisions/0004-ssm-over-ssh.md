# 0004. SSM Session Manager instead of SSH for the bastion

- **Status:** Accepted
- **Date:** 2026-09-23

## Context

With a private-only API ([ADR 0003](0003-private-only-api-endpoint.md)),
operators need a way into the VPC. The traditional bastion is an EC2 instance
in a public subnet with a public IP, port 22 open (ideally to one CIDR), and
an SSH key pair that has to be distributed, rotated and revoked.

## Decision

The bastion lives in a **private subnet** with **no public IP, no key pair
and no inbound rules**. Access is through AWS Systems Manager Session Manager:

- The SSM Agent on the instance connects out to the `ssm` / `ssmmessages` /
  `ec2messages` interface endpoints. Nothing ever connects in.
- Operators authenticate with IAM (`ssm:StartSession`). MFA and SSO apply,
  and access is granted or revoked centrally.
- Every session is recorded as a CloudTrail event. Session logging to S3 or
  CloudWatch can be added without touching the instance.
- Port forwarding (`AWS-StartPortForwardingSessionToRemoteHost`) tunnels
  `localhost:8443` to the private EKS endpoint, so kubectl runs on the laptop
  and the bastion needs no tools or internet.

## Consequences

**Good**
- No SSH keys anywhere: none to leak, rotate or revoke.
- Zero inbound attack surface: no port 22, no public IP, nothing to scan.
- Access control, audit and MFA go through IAM like everything else.

**Costs and limits**
- 3 extra interface endpoints (~$0.072/h in 2 AZs) plus a t3.micro
  (~$0.012/h). That's why `enable_bastion` defaults to `false`.
- Operators need the AWS CLI and the Session Manager plugin installed.
- The instance role needs `AmazonSSMManagedInstanceCore`, which is broader
  than strictly required, but it's the AWS-documented baseline.

## Alternatives considered

| Option | Why not |
|---|---|
| Public bastion with SSH | Public IP, open port, key management: all the things this avoids. |
| EC2 Instance Connect Endpoint | Also removes public IPs, but still uses SSH and keys (pushed temporarily). SSM also gives port forwarding and session logging. |
| Client VPN | Better for teams, but it's billed per subnet-association hour plus per connection hour, and needs certificate or SAML setup. Too heavy for a lab. |
