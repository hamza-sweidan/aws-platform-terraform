variable "name" {
  description = "Prefix for IAM role names, e.g. aws-platform-dev. Must be a plain string, not derived from the cluster, because the cluster needs these roles first."
  type        = string

  validation {
    # Longest suffix is "-eks-cluster" (12 chars); IAM role names max out at 64.
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]{2,50}$", var.name))
    error_message = "name must be 3-51 chars of letters, digits and hyphens."
  }
}

variable "cluster_name" {
  description = "EKS cluster name for access entries. Pass module.eks.cluster_name (not a literal) so access entries wait for the cluster."
  type        = string
}

variable "cluster_oidc_issuer_url" {
  description = "The cluster's OIDC issuer URL (module.eks.oidc_issuer_url), used to create the IAM OIDC provider for IRSA."
  type        = string

  validation {
    condition     = startswith(var.cluster_oidc_issuer_url, "https://")
    error_message = "cluster_oidc_issuer_url must start with https://."
  }
}

variable "kms_key_arn" {
  description = "KMS key the EKS cluster role may use for secrets envelope encryption."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/.+$", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN."
  }
}

variable "cluster_admin_principal_arns" {
  description = "IAM users or roles that get cluster-admin through EKS access entries, e.g. arn:aws:iam::111122223333:user/alice."
  type        = list(string)

  validation {
    condition     = length(var.cluster_admin_principal_arns) > 0
    error_message = "At least one admin principal is required. The cluster creator gets no implicit admin (bootstrap_cluster_creator_admin_permissions = false)."
  }

  validation {
    condition = alltrue([
      for arn in var.cluster_admin_principal_arns :
      can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(user|role)/.+$", arn))
    ])
    error_message = "Each entry must be an IAM user or role ARN. For SSO, use the role ARN without the aws-reserved/sso.amazonaws.com/ path."
  }
}

variable "tags" {
  description = "Extra tags for IAM resources."
  type        = map(string)
  default     = {}
}
