variable "cluster_name" {
  description = "Name of the EKS cluster."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_-]{0,99}$", var.cluster_name))
    error_message = "cluster_name must start with a letter and contain only letters, digits, - and _ (max 100)."
  }
}

variable "kubernetes_version" {
  description = "Kubernetes minor version. 1.36 is the EKS default in standard support until 2027-08."
  type        = string
  default     = "1.36"

  validation {
    condition     = can(regex("^1\\.[0-9]{2}$", var.kubernetes_version))
    error_message = "kubernetes_version must be a minor version such as 1.36."
  }
}

variable "vpc_id" {
  description = "VPC for the cluster security group."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for the control-plane ENIs and the node group. Must span at least two AZs and have the required VPC endpoints."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "EKS requires subnets in at least two Availability Zones."
  }
}

variable "cluster_role_arn" {
  description = "IAM role assumed by the EKS control plane (modules/iam)."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/.+$", var.cluster_role_arn))
    error_message = "cluster_role_arn must be an IAM role ARN."
  }
}

variable "node_role_arn" {
  description = "IAM role for worker nodes (modules/iam)."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/.+$", var.node_role_arn))
    error_message = "node_role_arn must be an IAM role ARN."
  }
}

variable "vpc_cni_role_arn" {
  description = "IRSA role for the vpc-cni add-on's aws-node service account (modules/iam)."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/.+$", var.vpc_cni_role_arn))
    error_message = "vpc_cni_role_arn must be an IAM role ARN."
  }
}

variable "kms_key_arn" {
  description = "KMS key for Kubernetes Secrets envelope encryption and the control-plane log group."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/.+$", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN."
  }
}

variable "enabled_log_types" {
  description = "Control-plane log types to send to CloudWatch Logs."
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  validation {
    condition     = alltrue([for t in var.enabled_log_types : contains(["api", "audit", "authenticator", "controllerManager", "scheduler"], t)])
    error_message = "Valid log types are api, audit, authenticator, controllerManager and scheduler."
  }
}

variable "log_retention_days" {
  description = "Retention for the control-plane log group."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a retention value CloudWatch Logs accepts."
  }
}

variable "api_client_security_group_ids" {
  description = "Security groups (for example the bastion's) allowed to reach the private API endpoint on 443. Nodes already have access through the EKS-managed cluster security group."
  type        = list(string)
  default     = []
}

variable "service_ipv4_cidr" {
  description = "CIDR for Kubernetes Service ClusterIPs. Must not overlap the VPC or anything it's peered with."
  type        = string
  default     = "172.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.service_ipv4_cidr, 0))
    error_message = "service_ipv4_cidr must be a valid IPv4 CIDR."
  }
}

variable "node_ami_type" {
  description = "EKS-optimized AMI family for the managed node group."
  type        = string
  default     = "AL2023_x86_64_STANDARD"

  validation {
    condition     = contains(["AL2023_x86_64_STANDARD", "AL2023_ARM_64_STANDARD", "BOTTLEROCKET_x86_64", "BOTTLEROCKET_ARM_64"], var.node_ami_type)
    error_message = "node_ami_type must be an AL2023 or Bottlerocket AMI type."
  }
}

variable "node_instance_types" {
  description = "Instance types for the node group. With SPOT, list several of the same size to improve capacity."
  type        = list(string)
  default     = ["t3.medium"]

  validation {
    condition     = length(var.node_instance_types) > 0
    error_message = "Provide at least one instance type."
  }
}

variable "node_capacity_type" {
  description = "ON_DEMAND or SPOT."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "node_min_size" {
  description = "Minimum number of nodes."
  type        = number
  default     = 1

  validation {
    condition     = var.node_min_size >= 1
    error_message = "node_min_size must be at least 1 (CoreDNS needs somewhere to run)."
  }
}

variable "node_max_size" {
  description = "Maximum number of nodes."
  type        = number
  default     = 3

  validation {
    condition     = var.node_max_size >= var.node_min_size
    error_message = "node_max_size must be >= node_min_size."
  }
}

variable "node_desired_size" {
  description = "Initial number of nodes. Ignored after creation so an autoscaler can own it."
  type        = number
  default     = 2

  validation {
    condition     = var.node_desired_size >= var.node_min_size && var.node_desired_size <= var.node_max_size
    error_message = "node_desired_size must be between node_min_size and node_max_size."
  }
}

variable "node_disk_size_gib" {
  description = "Root EBS volume size (gp3, encrypted) per node."
  type        = number
  default     = 20

  validation {
    condition     = var.node_disk_size_gib >= 20 && var.node_disk_size_gib <= 200
    error_message = "node_disk_size_gib must be between 20 and 200."
  }
}

variable "addon_versions" {
  description = "Optional pinned versions per add-on (keys: vpc-cni, kube-proxy, coredns). Unset add-ons use the EKS default for kubernetes_version."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for k in keys(var.addon_versions) : contains(["vpc-cni", "kube-proxy", "coredns"], k)])
    error_message = "addon_versions keys must be vpc-cni, kube-proxy or coredns."
  }
}

variable "enable_network_policy" {
  description = "Enforce Kubernetes NetworkPolicy with the VPC CNI's eBPF network policy agent."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Extra tags for EKS resources."
  type        = map(string)
  default     = {}
}

variable "node_tags" {
  description = "Tags for node EC2 instances and volumes. Provider default_tags don't reach launch template tag_specifications, so pass them here for cost allocation."
  type        = map(string)
  default     = {}
}
