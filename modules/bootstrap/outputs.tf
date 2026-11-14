output "account_id" {
  description = "AWS account ID the module was applied to."
  value       = local.account_id
}

output "region" {
  description = "AWS region the module was applied to."
  value       = local.region
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC provider (created or passed in)."
  value       = local.oidc_provider_arn
}

output "ci_role_arn" {
  description = "ARN of the CI role. Use as role-to-assume in aws-actions/configure-aws-credentials."
  value       = aws_iam_role.ci.arn
}

output "ci_role_name" {
  description = "Name of the CI role."
  value       = aws_iam_role.ci.name
}

output "state_bucket_name" {
  description = "Name of the remote state bucket, or null if not created."
  value       = try(aws_s3_bucket.state[0].bucket, null)
}

output "state_bucket_arn" {
  description = "ARN of the remote state bucket, or null if not created."
  value       = try(aws_s3_bucket.state[0].arn, null)
}

output "lock_table_name" {
  description = "Name of the DynamoDB lock table, or null if not created."
  value       = try(aws_dynamodb_table.lock[0].name, null)
}

output "ecr_repository_urls" {
  description = "Map of repo_name => ECR repository URL."
  value       = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}

output "ecr_repository_arns" {
  description = "Map of repo_name => ECR repository ARN."
  value       = { for k, r in aws_ecr_repository.this : k => r.arn }
}
