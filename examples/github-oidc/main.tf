# Example root configuration that consumes the bootstrap module.
# Copy this folder into the consuming repo (e.g. infrastructure/bootstrap/)
# and change the `source` to the git URL shown in the README.

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }

  # Configured at init time by scripts/bootstrap.sh (-backend-config=...).
  backend "s3" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project     = var.project
      environment = var.environment
    }
  }
}

module "bootstrap" {
  # In a consuming repo use:
  # source = "git::ssh://git@github.com/jacklavelle286/terraform-bootstrap.git//modules/bootstrap?ref=v1.0.0"
  source = "../../modules/bootstrap"

  project     = var.project
  environment = var.environment
  tags        = var.extra_tags

  trusted_subs     = var.trusted_subs
  role_policy_arns = var.role_policy_arns

  create_oidc_provider = var.create_oidc_provider
  oidc_provider_arn    = var.oidc_provider_arn

  ecr_repos = var.ecr_repos
}
