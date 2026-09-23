variable "region" {
  description = "AWS region for the environment."
  type        = string
  default     = "eu-central-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.region))
    error_message = "region must look like an AWS region code, e.g. eu-central-1."
  }
}

variable "project" {
  description = "Project name, used in resource names and the Project tag."
  type        = string
  default     = "aws-platform"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.project))
    error_message = "project must be 3-21 chars of lowercase letters, digits and hyphens."
  }
}

variable "environment" {
  description = "Environment name, used in resource names and the Environment tag."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "owner" {
  description = "Owner tag value, e.g. your GitHub handle or team."
  type        = string

  validation {
    condition     = length(trimspace(var.owner)) > 0
    error_message = "owner must not be empty."
  }
}

variable "availability_zones" {
  description = "Exactly which AZs to use. Pinned so the subnet layout never moves."
  type        = list(string)
  default     = ["eu-central-1a", "eu-central-1b"]

  validation {
    condition     = alltrue([for az in var.availability_zones : startswith(az, var.region)])
    error_message = "Every Availability Zone must belong to var.region."
  }
}

variable "vpc_cidr" {
  description = "VPC IPv4 CIDR."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) <= 20
    error_message = "vpc_cidr must be a valid IPv4 CIDR of /20 or larger."
  }
}

variable "kubernetes_version" {
  description = "EKS Kubernetes minor version."
  type        = string
  default     = "1.36"

  validation {
    condition     = can(regex("^1\\.[0-9]{2}$", var.kubernetes_version))
    error_message = "kubernetes_version must look like 1.36."
  }
}

variable "cluster_admin_principal_arns" {
  description = "IAM users/roles that get cluster-admin via EKS access entries. Put your own IAM user ARN here (terraform.tfvars)."
  type        = list(string)

  validation {
    condition     = length(var.cluster_admin_principal_arns) > 0
    error_message = "At least one admin principal is required or nobody can use the cluster."
  }

  validation {
    condition = alltrue([
      for arn in var.cluster_admin_principal_arns :
      can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(user|role)/.+$", arn))
    ])
    error_message = "Each entry must be an IAM user or role ARN."
  }
}

variable "node_instance_types" {
  description = "Node instance types."
  type        = list(string)
  default     = ["t3.medium"]

  validation {
    condition     = length(var.node_instance_types) > 0
    error_message = "Provide at least one instance type."
  }
}

variable "node_capacity_type" {
  description = "ON_DEMAND or SPOT. SPOT is ~60-70% cheaper for a lab that can tolerate interruptions."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "node_min_size" {
  description = "Minimum node count."
  type        = number
  default     = 1

  validation {
    condition     = var.node_min_size >= 1
    error_message = "node_min_size must be at least 1."
  }
}

variable "node_desired_size" {
  description = "Initial node count (one per AZ by default)."
  type        = number
  default     = 2

  validation {
    condition     = var.node_desired_size >= var.node_min_size && var.node_desired_size <= var.node_max_size
    error_message = "node_desired_size must be between node_min_size and node_max_size."
  }
}

variable "node_max_size" {
  description = "Maximum node count."
  type        = number
  default     = 3

  validation {
    condition     = var.node_max_size >= var.node_min_size && var.node_max_size <= 10
    error_message = "node_max_size must be >= node_min_size and <= 10 for this lab."
  }
}

variable "enable_bastion" {
  description = "Create the SSM bastion and its three SSM interface endpoints (~$0.08/h extra). Needed for kubectl access to the private API."
  type        = bool
  default     = false
}

variable "enable_flow_logs" {
  description = "Send VPC flow logs to CloudWatch Logs."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Retention for control-plane and flow log groups."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365], var.log_retention_days)
    error_message = "log_retention_days must be a CloudWatch retention value up to 365."
  }
}

variable "ecr_repositories" {
  description = "Private ECR repositories to create for mirrored images."
  type        = set(string)
  default     = ["mirror/nginx-unprivileged"]

  validation {
    condition     = alltrue([for r in var.ecr_repositories : can(regex("^[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*$", r))])
    error_message = "ECR repository names must be lowercase and may contain / . _ - separators."
  }
}
