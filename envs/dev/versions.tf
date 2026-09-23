terraform {
  required_version = "~> 1.16.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.66"
    }
  }

  # Partial configuration: bucket and region come from backend.hcl (generated
  # by bootstrap, gitignored), so the account-specific bucket name never
  # lands in a public repo.
  #   terraform init -backend-config=backend.hcl
  backend "s3" {
    key          = "envs/dev/terraform.tfstate"
    encrypt      = true
    use_lockfile = true # S3 native locking: writes envs/dev/terraform.tfstate.tflock
  }
}

provider "aws" {
  region = var.region

  # Applied to every taggable resource the provider creates, so cost reports
  # can be grouped by Project/Environment without tagging each resource.
  default_tags {
    tags = local.default_tags
  }
}
