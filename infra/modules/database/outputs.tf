output "address" {
  description = "Hostname the app connects to."
  value       = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "db_name" {
  value = aws_db_instance.this.db_name
}

output "username" {
  value = aws_db_instance.this.username
}

output "master_user_secret_arn" {
  description = "Secrets Manager secret holding the generated password."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "identifier" {
  value = aws_db_instance.this.identifier
}

output "subnet_group_name" {
  value = aws_db_subnet_group.this.name
}

output "parameter_group_name" {
  value = aws_db_parameter_group.this.name
}
