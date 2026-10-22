# The DocFlow environment. Modules are added phase by phase:
#   Phase 3: network, storage, database, queue
#   Phase 5: compute, edge
#   Phase 10: monitoring

data "aws_caller_identity" "current" {}

locals {
  name = "${var.project}-${var.environment}"
}

module "network" {
  source = "./modules/network"

  name = local.name
}

module "storage" {
  source = "./modules/storage"

  name = local.name
}

module "queue" {
  source = "./modules/queue"

  name = local.name
}

module "database" {
  source = "./modules/database"

  name               = local.name
  private_subnet_ids = module.network.private_subnet_ids
  security_group_id  = module.network.db_security_group_id
}

# The app's SECRET_KEY (signs login cookies), generated and kept in
# Secrets Manager instead of a .env file.
resource "random_password" "app_secret_key" {
  length  = 64
  special = false
}

resource "aws_secretsmanager_secret" "app_secret_key" {
  name        = "${local.name}/app-secret-key"
  description = "DocFlow SECRET_KEY used to sign session cookies"

  # Delete immediately on destroy, so tomorrow's apply can reuse the name.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "app_secret_key" {
  secret_id     = aws_secretsmanager_secret.app_secret_key.id
  secret_string = random_password.app_secret_key.result
}
