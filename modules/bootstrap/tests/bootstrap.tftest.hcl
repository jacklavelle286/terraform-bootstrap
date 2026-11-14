# Run from modules/bootstrap:  terraform init && terraform test
# Uses a mocked AWS provider, so no credentials are needed.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_region" {
    defaults = { region = "eu-west-2" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" }
  }
}

variables {
  project      = "demo"
  environment  = "staging"
  trusted_subs = ["repo:my-org/demo:*"]
  ecr_repos    = [{ repo_name = "backend" }, { repo_name = "worker" }]
}

run "defaults" {
  command = apply

  assert {
    condition     = aws_iam_role.ci.name == "demo-staging-github-oidc"
    error_message = "Default role name is wrong."
  }

  assert {
    condition     = output.state_bucket_name == "123456789012-eu-west-2-demo-staging"
    error_message = "Default state bucket name is wrong."
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.this) == 1
    error_message = "OIDC provider should be created by default."
  }

  assert {
    condition     = length(aws_dynamodb_table.lock) == 0
    error_message = "Lock table should not be created by default."
  }

  assert {
    condition     = toset(keys(output.ecr_repository_urls)) == toset(["backend", "worker"])
    error_message = "ECR repos should be keyed by repo_name."
  }

  assert {
    condition     = aws_ecr_repository.this["backend"].name == "demo-staging-eu-west-2-backend"
    error_message = "ECR repo name is wrong."
  }

  assert {
    condition     = aws_s3_bucket.state[0].force_destroy == false
    error_message = "State bucket must not force_destroy by default."
  }
}

run "existing_oidc_provider" {
  command = apply

  variables {
    create_oidc_provider = false
    oidc_provider_arn    = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    role_name            = "github-federation"
    create_state_bucket  = false
    create_lock_table    = true
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.this) == 0
    error_message = "OIDC provider should not be created."
  }

  assert {
    condition     = output.oidc_provider_arn == var.oidc_provider_arn
    error_message = "Passed-in OIDC provider ARN should be used."
  }

  assert {
    condition     = output.state_bucket_name == null
    error_message = "State bucket should not be created."
  }

  assert {
    condition     = output.lock_table_name == "123456789012-eu-west-2-demo-staging"
    error_message = "Lock table name should default to the bucket naming scheme."
  }
}

run "missing_oidc_arn_fails" {
  command = plan

  variables {
    create_oidc_provider = false
  }

  expect_failures = [var.oidc_provider_arn]
}
