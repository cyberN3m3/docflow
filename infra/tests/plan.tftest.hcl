# Offline test: plans the whole environment against fake ("mock") AWS
# providers. It catches mistakes `terraform validate` can't see (wrong types
# in for_each, broken references, invalid expressions) without an AWS
# account or credentials. Run with:  terraform -chdir=infra test

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a", "us-east-1b"] }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_ecr_repository" {
    defaults = { repository_url = "123456789012.dkr.ecr.us-east-1.amazonaws.com/docflow" }
  }
  mock_resource "aws_db_instance" {
    defaults = { master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:x", kms_key_id = "k", secret_status = "active" }] }
  }
}
mock_provider "random" {}

variables {
  image_tag   = "abc1234"
  alert_email = "test@example.com"
}

run "plan" {
  command = plan

  assert {
    condition     = module.monitoring.dashboard_name == "docflow-demo"
    error_message = "The dashboard should be named after the environment."
  }
}
