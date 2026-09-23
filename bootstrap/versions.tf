terraform {
  # Root modules pin to a patch series. S3 native state locking
  # (use_lockfile) went GA in 1.11, so anything older can't use this backend.
  required_version = "~> 1.16.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.66"
    }
  }

  # No backend block on purpose: this configuration creates the state bucket,
  # so its own state has to start life locally (chicken-and-egg).
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      Environment = "shared"
      Owner       = var.owner
      ManagedBy   = "Terraform"
    }
  }
}
