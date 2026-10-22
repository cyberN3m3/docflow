output "account_id" {
  description = "The AWS account Terraform is working in."
  value       = data.aws_caller_identity.current.account_id
}

output "region" {
  description = "The AWS region Terraform is working in."
  value       = var.region
}
