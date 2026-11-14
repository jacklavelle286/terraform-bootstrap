# ---------------------------------------------------------------------------
# Naming / tagging
# ---------------------------------------------------------------------------

variable "project" {
  description = "Project name. Used in resource names and tags."
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. staging, prod). Used in resource names and tags."
  type        = string
}

variable "tags" {
  description = "Extra tags applied to every resource created by this module."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# GitHub OIDC provider
# ---------------------------------------------------------------------------

variable "create_oidc_provider" {
  description = <<-EOT
    Create the account-wide OIDC identity provider. AWS allows only one provider
    per URL per account, so set this to false (and pass oidc_provider_arn) when
    another stack in the same account already created it.
  EOT
  type        = bool
  default     = true
}

variable "oidc_provider_arn" {
  description = "ARN of an existing OIDC provider. Required when create_oidc_provider = false."
  type        = string
  default     = null

  validation {
    condition     = var.create_oidc_provider || var.oidc_provider_arn != null
    error_message = "oidc_provider_arn must be set when create_oidc_provider = false."
  }
}

variable "oidc_url" {
  description = "OIDC issuer URL."
  type        = string
  default     = "https://token.actions.githubusercontent.com"
}

variable "oidc_client_id_list" {
  description = "Audiences (client IDs) accepted by the OIDC provider."
  type        = list(string)
  default     = ["sts.amazonaws.com"]
}

variable "oidc_thumbprint_list" {
  description = "Thumbprints for the OIDC provider. AWS no longer validates these for GitHub, but the API still accepts them."
  type        = list(string)
  default     = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# ---------------------------------------------------------------------------
# CI role
# ---------------------------------------------------------------------------

variable "role_name" {
  description = "Name of the IAM role assumed by CI. Defaults to \"<project>-<environment>-github-oidc\"."
  type        = string
  default     = null
}

variable "trusted_subs" {
  description = <<-EOT
    OIDC subject claims allowed to assume the role (StringLike, wildcards allowed).
    Examples:
      "repo:my-org/my-repo:*"                    any ref / environment
      "repo:my-org/my-repo:ref:refs/heads/main"  main branch only
      "repo:my-org/my-repo:environment:prod"     GitHub environment "prod"
  EOT
  type        = list(string)

  validation {
    condition     = length(var.trusted_subs) > 0
    error_message = "trusted_subs must contain at least one subject."
  }
}

variable "role_policy_arns" {
  description = "Managed policy ARNs to attach to the CI role (e.g. arn:aws:iam::aws:policy/AdministratorAccess)."
  type        = list(string)
  default     = []
}

variable "role_inline_policy_json" {
  description = "Optional inline policy document (JSON) attached to the CI role."
  type        = string
  default     = null
}

variable "role_max_session_duration" {
  description = "Maximum session duration for the CI role, in seconds."
  type        = number
  default     = 3600
}

# ---------------------------------------------------------------------------
# Remote state for the consuming project's main stack
# ---------------------------------------------------------------------------

variable "create_state_bucket" {
  description = "Create an S3 bucket for the consuming project's Terraform state."
  type        = bool
  default     = true
}

variable "state_bucket_name" {
  description = "Override the state bucket name. Defaults to \"<account_id>-<region>-<project>-<environment>\"."
  type        = string
  default     = null
}

variable "state_bucket_force_destroy" {
  description = "Allow Terraform to delete the state bucket even when it contains objects. Keep false outside of throwaway environments."
  type        = bool
  default     = false
}

variable "create_lock_table" {
  description = <<-EOT
    Create a DynamoDB lock table. Not needed on Terraform >= 1.10, which locks
    natively in S3 (backend "s3" { use_lockfile = true }). Only enable it for
    older Terraform versions or while migrating an existing backend.
  EOT
  type        = bool
  default     = false
}

variable "lock_table_name" {
  description = "Override the DynamoDB lock table name. Defaults to the state bucket name."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# ECR
# ---------------------------------------------------------------------------

variable "ecr_repos" {
  description = "ECR repositories to create. Each is named \"<project>-<environment>-<region>-<repo_name>\"."
  type = list(object({
    repo_name = string
  }))
  default = []
}

variable "ecr_image_tag_mutability" {
  description = "MUTABLE or IMMUTABLE."
  type        = string
  default     = "MUTABLE"

  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.ecr_image_tag_mutability)
    error_message = "ecr_image_tag_mutability must be MUTABLE or IMMUTABLE."
  }
}

variable "ecr_scan_on_push" {
  description = "Enable basic image scanning on push."
  type        = bool
  default     = true
}

variable "ecr_force_delete" {
  description = "Allow deleting ECR repositories that still contain images."
  type        = bool
  default     = false
}

variable "ecr_keep_image_count" {
  description = "Number of most-recent images to keep per repository. Untagged images expire after 1 day."
  type        = number
  default     = 5
}
