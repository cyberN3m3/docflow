# Managed PostgreSQL. Replaces the Postgres container on the legacy server.

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db"
  subnet_ids = var.private_subnet_ids

  tags = { Name = "${var.name}-db" }
}

# Database settings: refuse unencrypted connections, and log slow queries and
# schema changes (useful for spotting abuse and performance problems).
resource "aws_db_parameter_group" "this" {
  name   = "${var.name}-postgres16"
  family = "postgres16"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000" # log any query slower than 1 second
  }

  parameter {
    name  = "log_statement"
    value = "ddl" # log CREATE, ALTER and DROP, never the data
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }
}

# Created by Terraform (instead of letting RDS create it) so it has a
# retention period and is deleted with the environment.
resource "aws_cloudwatch_log_group" "postgres" {
  name              = "/aws/rds/instance/${var.name}-db/postgresql"
  retention_in_days = 7

  #checkov:skip=CKV_AWS_158:Encrypted with CloudWatch's AWS-managed key; a customer-managed KMS key costs $1/month.
  #checkov:skip=CKV_AWS_338:7 days in a demo; production compliance would need 1 year.
}

resource "aws_db_instance" "this" {
  identifier = "${var.name}-db"

  # Accepted risks (see docs/security.md):
  #checkov:skip=CKV_AWS_157:Single-AZ to save about $12/month; production would use Multi-AZ.
  #checkov:skip=CKV_AWS_293:Deletion protection is off so the environment can be destroyed after every session. Production: on.
  #checkov:skip=CKV_AWS_353:Performance Insights isn't needed for a database this small.
  #checkov:skip=CKV_AWS_118:Enhanced monitoring skipped; standard CloudWatch metrics and alarms cover CPU, storage and connections.
  #checkov:skip=CKV_AWS_161:The app uses a password from Secrets Manager (rotated by RDS) over TLS; IAM database auth would need app changes.

  engine         = "postgres"
  engine_version = "16"
  instance_class = var.instance_class

  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "docflow"
  username = "docflow"

  # RDS generates the password and keeps it in Secrets Manager.
  # Nobody types it, and it never appears in code or Terraform state.
  manage_master_user_password = true

  parameter_group_name            = aws_db_parameter_group.this.name
  enabled_cloudwatch_logs_exports = ["postgresql"]

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]
  publicly_accessible    = false

  # Single-AZ to keep costs down. Production would use multi_az = true.
  multi_az = false

  backup_retention_period = 1
  copy_tags_to_snapshot   = true

  auto_minor_version_upgrade = true
  apply_immediately          = true

  # Demo settings so the daily `terraform destroy` works cleanly.
  # Production would enable deletion protection and keep a final snapshot.
  deletion_protection = false
  skip_final_snapshot = true

  depends_on = [aws_cloudwatch_log_group.postgres]
}
