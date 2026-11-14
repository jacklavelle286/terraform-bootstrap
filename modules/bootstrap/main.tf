data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  tags = merge(
    {
      project     = var.project
      environment = var.environment
      managed-by  = "terraform"
      module      = "terraform-bootstrap"
    },
    var.tags,
  )

  oidc_host         = replace(var.oidc_url, "https://", "")
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.this[0].arn : var.oidc_provider_arn

  role_name         = coalesce(var.role_name, "${var.project}-${var.environment}-github-oidc")
  state_bucket_name = coalesce(var.state_bucket_name, "${local.account_id}-${local.region}-${var.project}-${var.environment}")
  lock_table_name   = coalesce(var.lock_table_name, local.state_bucket_name)
}

# ---------------------------------------------------------------------------
# OIDC provider + CI role
# ---------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "this" {
  count = var.create_oidc_provider ? 1 : 0

  url             = var.oidc_url
  client_id_list  = var.oidc_client_id_list
  thumbprint_list = var.oidc_thumbprint_list
  tags            = local.tags
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = var.oidc_client_id_list
    }

    condition {
      test     = "StringLike"
      variable = "${local.oidc_host}:sub"
      values   = var.trusted_subs
    }
  }
}

resource "aws_iam_role" "ci" {
  name                 = local.role_name
  assume_role_policy   = data.aws_iam_policy_document.assume_role.json
  max_session_duration = var.role_max_session_duration
  tags                 = local.tags
}

resource "aws_iam_role_policy_attachment" "ci" {
  for_each = toset(var.role_policy_arns)

  role       = aws_iam_role.ci.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "ci_inline" {
  count = var.role_inline_policy_json != null ? 1 : 0

  name   = "${local.role_name}-inline"
  role   = aws_iam_role.ci.id
  policy = var.role_inline_policy_json
}

# ---------------------------------------------------------------------------
# Remote state bucket (+ optional legacy DynamoDB lock table)
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  count = var.create_state_bucket ? 1 : 0

  bucket        = local.state_bucket_name
  force_destroy = var.state_bucket_force_destroy
  tags          = local.tags
}

resource "aws_s3_bucket_versioning" "state" {
  count = var.create_state_bucket ? 1 : 0

  bucket = aws_s3_bucket.state[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  count = var.create_state_bucket ? 1 : 0

  bucket = aws_s3_bucket.state[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  count = var.create_state_bucket ? 1 : 0

  bucket                  = aws_s3_bucket.state[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  count = var.create_state_bucket ? 1 : 0

  bucket = aws_s3_bucket.state[0].id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

data "aws_iam_policy_document" "state_tls_only" {
  count = var.create_state_bucket ? 1 : 0

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state[0].arn,
      "${aws_s3_bucket.state[0].arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  count = var.create_state_bucket ? 1 : 0

  bucket = aws_s3_bucket.state[0].id
  policy = data.aws_iam_policy_document.state_tls_only[0].json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

resource "aws_dynamodb_table" "lock" {
  count = var.create_lock_table ? 1 : 0

  name         = local.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# ECR
# ---------------------------------------------------------------------------

# Keyed by repo name (not list index) so adding/removing a repo only touches
# that repo.
resource "aws_ecr_repository" "this" {
  for_each = { for r in var.ecr_repos : r.repo_name => r }

  name                 = "${var.project}-${var.environment}-${local.region}-${each.key}"
  image_tag_mutability = var.ecr_image_tag_mutability
  force_delete         = var.ecr_force_delete
  tags                 = local.tags

  image_scanning_configuration {
    scan_on_push = var.ecr_scan_on_push
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the ${var.ecr_keep_image_count} most-recent images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.ecr_keep_image_count
        }
        action = { type = "expire" }
      },
    ]
  })
}
