# Shared TFLint config. Run from the repo root:
#   tflint --init
#   tflint --recursive --config "$(pwd)/.tflint.hcl"

config {
  # Also lint local module calls (envs/dev -> modules/*) with the caller's inputs.
  call_module_type = "local"
}

# Core Terraform language rules. "all" adds naming conventions, documented
# variables/outputs, typed variables and standard module structure on top
# of the "recommended" preset.
plugin "terraform" {
  enabled = true
  preset  = "all"
}

# AWS-specific rules: invalid instance types, AMI/type mismatches,
# deprecated arguments, tagging, etc. Pinned so CI is reproducible.
plugin "aws" {
  enabled = true
  version = "0.49.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# Azure-specific rules for azure/: invalid locations, SKUs, name formats and
# enum values the azurerm provider only rejects at apply time. Each ruleset
# only inspects its own provider's resources, so both run on every directory.
plugin "azurerm" {
  enabled = true
  version = "0.32.0"
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}
