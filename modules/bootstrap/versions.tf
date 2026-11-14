terraform {
  required_version = ">= 1.9.0" # cross-variable validation

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }
}

# No provider block here on purpose: the calling configuration owns the
# provider (region, credentials, default_tags) and passes it in implicitly.
