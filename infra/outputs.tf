output "account_id" {
  description = "The AWS account Terraform is working in."
  value       = data.aws_caller_identity.current.account_id
}

output "region" {
  description = "The AWS region Terraform is working in."
  value       = var.region
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "files_bucket" {
  value = module.storage.bucket_name
}

output "jobs_queue_url" {
  value = module.queue.queue_url
}

output "db_address" {
  value = module.database.address
}

output "db_password_secret_arn" {
  value = module.database.master_user_secret_arn
}

output "app_secret_key_arn" {
  value = aws_secretsmanager_secret.app_secret_key.arn
}
