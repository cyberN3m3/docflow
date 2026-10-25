output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "web_service_name" {
  value = aws_ecs_service.web.name
}

output "worker_service_name" {
  value = aws_ecs_service.worker.name
}

output "web_task_family" {
  description = "Task definition used for one-off jobs, such as the migration."
  value       = aws_ecs_task_definition.web.family
}

output "worker_log_group_name" {
  value = aws_cloudwatch_log_group.worker.name
}
