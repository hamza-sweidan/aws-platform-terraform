output "state_bucket_name" {
  description = "Name of the S3 bucket that stores Terraform state."
  value       = aws_s3_bucket.state.id
}

output "state_bucket_arn" {
  description = "ARN of the state bucket, for IAM policies that grant state access."
  value       = aws_s3_bucket.state.arn
}

output "region" {
  description = "Region of the state bucket."
  value       = var.region
}

output "backend_config" {
  description = "Partial backend config for envs/*. Write it with: terraform output -raw backend_config > ../envs/dev/backend.hcl"
  value       = <<-EOT
    bucket = "${aws_s3_bucket.state.id}"
    region = "${var.region}"
  EOT
}

output "budget_name" {
  description = "Name of the monthly cost budget, or null if no alert email was given."
  value       = one(aws_budgets_budget.monthly[*].name)
}
