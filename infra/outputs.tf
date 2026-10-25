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

output "app_url" {
  description = "DocFlow's public HTTPS address."
  value       = "https://${module.edge.cloudfront_domain_name}"
}

output "alb_dns_name" {
  description = "The load balancer's own address. Visiting it directly should be refused."
  value       = module.edge.alb_dns_name
}

output "ecs_cluster" {
  value = module.compute.cluster_name
}

# --- Used by scripts/migrate/run-task.sh to start one-off tasks ---------------

output "web_task_family" {
  value = module.compute.web_task_family
}

output "public_subnet_ids_csv" {
  value = join(",", module.network.public_subnet_ids)
}

output "app_security_group_id" {
  value = module.network.app_security_group_id
}

# --- Phase 10 -------------------------------------------------------------------

output "dashboard_url" {
  description = "CloudWatch dashboard for DocFlow."
  value       = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards/dashboard/${module.monitoring.dashboard_name}"
}

output "alerts_topic_arn" {
  value = module.monitoring.alerts_topic_arn
}

# Used by the disaster recovery drills (scripts/dr/)
output "db_identifier" {
  value = module.database.identifier
}

output "db_subnet_group" {
  value = module.database.subnet_group_name
}

output "db_parameter_group" {
  value = module.database.parameter_group_name
}

output "db_security_group_id" {
  value = module.network.db_security_group_id
}

output "web_service_name" {
  value = module.compute.web_service_name
}
