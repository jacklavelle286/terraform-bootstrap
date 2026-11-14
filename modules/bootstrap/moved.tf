# Resource address renames from the original in-repo module
# (jacks-productivity-tool/infrastructure/modules/bootstrap). These let a stack
# that used that module switch to this one without destroying/recreating
# resources. Safe to keep: they are no-ops for fresh deployments.

moved {
  from = aws_iam_openid_connect_provider.github
  to   = aws_iam_openid_connect_provider.this[0]
}

moved {
  from = aws_iam_role.github_oidc_role
  to   = aws_iam_role.ci
}

moved {
  from = aws_s3_bucket.backend
  to   = aws_s3_bucket.state[0]
}

moved {
  from = aws_dynamodb_table.lock
  to   = aws_dynamodb_table.lock[0]
}

moved {
  from = aws_ecr_repository.lambda_repo
  to   = aws_ecr_repository.this
}

moved {
  from = aws_ecr_lifecycle_policy.lambda_repo
  to   = aws_ecr_lifecycle_policy.this
}
