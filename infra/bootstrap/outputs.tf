output "state_bucket" {
  description = "Name of the S3 bucket that stores Terraform state."
  value       = aws_s3_bucket.state.id
}

output "region" {
  description = "Region of the state bucket."
  value       = var.region
}