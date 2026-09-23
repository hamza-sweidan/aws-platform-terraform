terraform {
  # Reusable modules declare a floor, not a pin: the root module and its lock
  # file decide the exact versions.
  required_version = ">= 1.9, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }
}
