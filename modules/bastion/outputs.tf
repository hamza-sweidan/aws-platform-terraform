output "instance_id" {
  description = "Instance ID, the target for `aws ssm start-session`."
  value       = aws_instance.this.id
}

output "security_group_id" {
  description = "Bastion security group. Allow it in the EKS API security group."
  value       = aws_security_group.this.id
}

output "role_arn" {
  description = "ARN of the bastion instance role."
  value       = aws_iam_role.this.arn
}

output "private_ip" {
  description = "Private IP of the bastion."
  value       = aws_instance.this.private_ip
}
