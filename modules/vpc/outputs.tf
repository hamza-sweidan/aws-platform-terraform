output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "IPv4 CIDR of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "azs" {
  description = "Availability Zones the subnets were created in."
  value       = local.azs
}

output "public_subnet_ids" {
  description = "IDs of the public subnets (for internet-facing load balancers only)."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets. Only returned once the S3 and interface endpoints exist (see depends_on)."
  value       = aws_subnet.private[*].id

  # Contract: private subnets aren't usable until their endpoints exist.
  # Without this, EKS could launch nodes while ecr/ec2/sts endpoints are
  # still being created. With no NAT those nodes would fail to join and the
  # node group would time out after ~20 minutes. Anything built from these
  # IDs now waits for the endpoints automatically.
  depends_on = [
    aws_vpc_endpoint.s3,
    aws_vpc_endpoint.interface,
    aws_vpc_security_group_ingress_rule.endpoints_https,
    aws_route_table_association.private,
  ]
}

output "private_route_table_id" {
  description = "ID of the shared private route table."
  value       = aws_route_table.private.id
}

output "endpoint_security_group_id" {
  description = "Security group attached to all interface endpoints."
  value       = aws_security_group.endpoints.id
}

output "interface_endpoint_ids" {
  description = "Map of service short name to interface endpoint ID."
  value       = { for k, v in aws_vpc_endpoint.interface : k => v.id }
}

output "s3_gateway_endpoint_id" {
  description = "ID of the S3 gateway endpoint."
  value       = aws_vpc_endpoint.s3.id
}

output "flow_log_group_name" {
  description = "CloudWatch log group receiving VPC flow logs, or null when disabled."
  value       = one(aws_cloudwatch_log_group.flow_logs[*].name)
}
