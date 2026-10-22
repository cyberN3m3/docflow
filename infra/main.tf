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

# --- Phase 5: run the app ------------------------------------------------------

# The image registry lives in the bootstrap layer; look it up by name.
data "aws_ecr_repository" "app" {
  name = "docflow"
}

module "edge" {
  source = "./modules/edge"

  name                  = local.name
  vpc_id                = module.network.vpc_id
  public_subnet_ids     = module.network.public_subnet_ids
  alb_security_group_id = module.network.alb_security_group_id
}

module "compute" {
  source = "./modules/compute"

  name   = local.name
  region = var.region
  image  = "${data.aws_ecr_repository.app.repository_url}:${var.image_tag}"

  public_subnet_ids        = module.network.public_subnet_ids
  app_security_group_id    = module.network.app_security_group_id
  worker_security_group_id = module.network.worker_security_group_id
  target_group_arn         = module.edge.target_group_arn

  bucket_name = module.storage.bucket_name
  bucket_arn  = module.storage.bucket_arn

  queue_name = module.queue.queue_name
  queue_url  = module.queue.queue_url
  queue_arn  = module.queue.queue_arn

  db_address             = module.database.address
  db_name                = module.database.db_name
  db_username            = module.database.username
  db_password_secret_arn = module.database.master_user_secret_arn
  app_secret_key_arn     = aws_secretsmanager_secret.app_secret_key.arn
}
