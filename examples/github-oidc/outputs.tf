output "ci_role_arn" {
  value = module.bootstrap.ci_role_arn
}

output "state_bucket_name" {
  value = module.bootstrap.state_bucket_name
}

output "ecr_repository_urls" {
  value = module.bootstrap.ecr_repository_urls
}
