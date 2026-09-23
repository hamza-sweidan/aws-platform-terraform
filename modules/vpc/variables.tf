variable "name" {
  description = "Name prefix for every resource in the module, e.g. aws-platform-dev."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,40}$", var.name))
    error_message = "name must be 3-41 chars of lowercase letters, digits and hyphens."
  }
}

variable "cidr_block" {
  description = "IPv4 CIDR for the VPC. Private subnets get /20s carved from it (pods take VPC IPs with the VPC CNI), public subnets /24s."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition = (
      can(cidrhost(var.cidr_block, 0)) &&
      tonumber(split("/", var.cidr_block)[1]) >= 16 &&
      tonumber(split("/", var.cidr_block)[1]) <= 20
    )
    error_message = "cidr_block must be a valid IPv4 CIDR with a prefix between /16 and /20."
  }
}

variable "availability_zones" {
  description = "Availability Zone names to create one public and one private subnet in, e.g. [\"eu-central-1a\", \"eu-central-1b\"]. Explicit so the layout never shifts when AWS adds a zone. EKS needs at least two."
  type        = list(string)

  validation {
    condition     = length(var.availability_zones) >= 2 && length(var.availability_zones) <= 3
    error_message = "Provide 2 or 3 Availability Zones."
  }

  validation {
    condition     = length(distinct(var.availability_zones)) == length(var.availability_zones)
    error_message = "availability_zones must not contain duplicates."
  }
}

variable "interface_endpoints" {
  description = "AWS service short names to create interface endpoints for, e.g. ecr.api. Each becomes com.amazonaws.<region>.<name> in every private subnet."
  type        = set(string)
  default     = ["ecr.api", "ecr.dkr", "ec2", "sts", "logs"]

  validation {
    condition     = alltrue([for s in var.interface_endpoints : can(regex("^[a-z0-9][a-z0-9.-]*$", s))])
    error_message = "Each endpoint must be a service short name such as ecr.api or ssmmessages."
  }
}

variable "s3_endpoint_extra_bucket_arns" {
  description = "Object ARNs (arn:aws:s3:::bucket/*) that workloads may read through the S3 gateway endpoint, in addition to the ECR layer bucket."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.s3_endpoint_extra_bucket_arns : can(regex("^arn:aws[a-z-]*:s3:::[a-z0-9.-]+/.+$", a))])
    error_message = "Entries must be S3 object ARNs such as arn:aws:s3:::my-bucket/*."
  }
}

variable "enable_flow_logs" {
  description = "Send VPC flow logs (all traffic) to CloudWatch Logs."
  type        = bool
  default     = false
}

variable "flow_logs_log_group_name" {
  description = "CloudWatch log group name for flow logs. Passed in so the caller can also reference it in a KMS key policy."
  type        = string
  default     = null

  validation {
    condition     = var.flow_logs_log_group_name == null || can(regex("^[a-zA-Z0-9_./#-]{1,512}$", var.flow_logs_log_group_name))
    error_message = "flow_logs_log_group_name must be a valid CloudWatch log group name."
  }
}

variable "flow_logs_kms_key_arn" {
  description = "KMS key ARN to encrypt the flow log group. The key policy must allow the CloudWatch Logs service."
  type        = string
  default     = null
}

variable "flow_logs_retention_days" {
  description = "Retention for the flow log group."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.flow_logs_retention_days)
    error_message = "flow_logs_retention_days must be a retention value CloudWatch Logs accepts."
  }
}

variable "tags" {
  description = "Extra tags for every resource. Provider default_tags already cover Project/Environment/Owner/ManagedBy."
  type        = map(string)
  default     = {}
}
