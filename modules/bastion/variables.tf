variable "name" {
  description = "Name for the instance, role and security group."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]{2,50}$", var.name))
    error_message = "name must be 3-51 chars of letters, digits and hyphens."
  }
}

variable "vpc_id" {
  description = "VPC to place the bastion in."
  type        = string
}

variable "vpc_cidr_block" {
  description = "VPC CIDR. Egress is limited to HTTPS inside it (the SSM endpoints and the EKS API)."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr_block, 0))
    error_message = "vpc_cidr_block must be a valid IPv4 CIDR."
  }
}

variable "subnet_id" {
  description = "Private subnet for the instance. It must have the ssm, ssmmessages and ec2messages interface endpoints."
  type        = string
}

variable "instance_type" {
  description = "Instance type. The AMI is x86_64, so use an x86 type."
  type        = string
  default     = "t3.micro"

  validation {
    condition     = !can(regex("^[a-z0-9]+g[a-z]*\\.", var.instance_type))
    error_message = "Graviton (arm64) instance types don't match the x86_64 AMI."
  }
}

variable "ami_ssm_parameter" {
  description = "Public SSM parameter holding the AMI ID. The default tracks the latest Amazon Linux 2023, which ships with the SSM Agent."
  type        = string
  default     = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

variable "tags" {
  description = "Extra tags."
  type        = map(string)
  default     = {}
}
