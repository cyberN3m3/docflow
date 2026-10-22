# Managed PostgreSQL. Replaces the Postgres container on the legacy server.

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db"
  subnet_ids = var.private_subnet_ids

  tags = { Name = "${var.name}-db" }
}

resource "aws_db_instance" "this" {
  identifier = "${var.name}-db"

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
}
