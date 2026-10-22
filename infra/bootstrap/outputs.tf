output "state_bucket" {
  description = "Name of the S3 bucket that stores Terraform state."
  value       = aws_s3_bucket.state.id
}

output "region" {
  description = "Region of the state bucket."
  value       = var.region
}
output "ecr_repository_url" {
  description = "Where to push DocFlow Docker images."
  value       = aws_ecr_repository.app.repository_url
}

output "github_deploy_role_arn" {
  description = "Set as the GitHub Actions variable AWS_DEPLOY_ROLE_ARN."
  value       = aws_iam_role.github_deploy.arn
}

output "github_plan_role_arn" {
  description = "Set as the GitHub Actions variable AWS_PLAN_ROLE_ARN."
  value       = aws_iam_role.github_plan.arn
}
