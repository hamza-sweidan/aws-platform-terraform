variable "name" {
  description = "Name for the key alias (alias/<name>) and tags."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9/_-]{1,200}$", var.name)) && !startswith(var.name, "aws")
    error_message = "name may contain letters, digits, /, _ and -, and must not start with 'aws' (reserved for AWS managed keys)."
  }
}

variable "description" {
  description = "Human-readable key description shown in the KMS console."
  type        = string
  default     = "Platform key: EKS secrets envelope encryption and CloudWatch log groups"
}

variable "deletion_window_in_days" {
  description = "Waiting period before a scheduled key deletion completes. Anything encrypted with the key is unrecoverable once it's gone."
  type        = number
  default     = 7

  validation {
    condition     = var.deletion_window_in_days >= 7 && var.deletion_window_in_days <= 30
    error_message = "deletion_window_in_days must be between 7 and 30."
  }
}

variable "cloudwatch_log_group_names" {
  description = "Exact CloudWatch log group names allowed to use this key. CloudWatch Logs gets no access to any other log group."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Extra tags for the key."
  type        = map(string)
  default     = {}
}
