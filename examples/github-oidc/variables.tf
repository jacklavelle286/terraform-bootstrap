variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "region" {
  type = string
}

# Read by scripts/bootstrap.sh to guard against applying to the wrong account.
# Declared here so Terraform doesn't warn about an undeclared tfvars value.
variable "aws_account_id" {
  type    = string
  default = null
}

variable "extra_tags" {
  type    = map(string)
  default = {}
}

variable "trusted_subs" {
  type = list(string)
}

variable "role_policy_arns" {
  type    = list(string)
  default = []
}

variable "create_oidc_provider" {
  type    = bool
  default = true
}

variable "oidc_provider_arn" {
  type    = string
  default = null
}

variable "ecr_repos" {
  type = list(object({
    repo_name = string
  }))
  default = []
}
