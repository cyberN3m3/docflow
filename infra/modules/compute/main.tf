# Runs DocFlow on ECS Fargate: a web service behind the load balancer and a
# worker service with Gotenberg as a sidecar. No servers to manage.

resource "aws_ecs_cluster" "this" {
  name = var.name

  #checkov:skip=CKV_AWS_65:Container Insights is switched on in Phase 10 (monitoring).
}

# Fargate Spot (Phase 9): spare AWS capacity at up to 70% off, which AWS can
# reclaim with a 2-minute warning. Good for the worker, bad for the website.
resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

resource "aws_cloudwatch_log_group" "web" {
  name              = "/ecs/${var.name}/web"
  retention_in_days = var.log_retention_days

  #checkov:skip=CKV_AWS_158:Encrypted with CloudWatch's AWS-managed key; a customer-managed KMS key costs $1/month.
  #checkov:skip=CKV_AWS_338:7 days in a demo; production compliance would need 1 year.
}

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/ecs/${var.name}/worker"
  retention_in_days = var.log_retention_days

  #checkov:skip=CKV_AWS_158:Encrypted with CloudWatch's AWS-managed key; a customer-managed KMS key costs $1/month.
  #checkov:skip=CKV_AWS_338:7 days in a demo; production compliance would need 1 year.
}

locals {
  # Settings shared by web and worker. Only non-secret values go here.
  app_environment = [
    { name = "STORAGE_BACKEND", value = "s3" },
    { name = "S3_BUCKET", value = var.bucket_name },
    { name = "AWS_REGION", value = var.region },
    { name = "CELERY_BROKER_URL", value = "sqs://" },
    { name = "SQS_QUEUE_URL", value = var.queue_url },
    { name = "DB_HOST", value = var.db_address },
    { name = "DB_NAME", value = var.db_name },
    { name = "DB_USER", value = var.db_username },
    { name = "COOKIE_SECURE", value = "true" },
    { name = "MAX_UPLOAD_MB", value = "20" },
  ]

  # Read-only containers: an attacker who gets code execution can't modify
  # the app or drop tools on disk. /tmp is the only writable place (FastAPI
  # stores large uploads there while they are being received).
  tmp_mount = [{ sourceVolume = "tmp", containerPath = "/tmp", readOnly = false }]

  # Secrets are injected by ECS at start-up, straight from Secrets Manager.
  # They never appear in the task definition, the console or Terraform code.
  app_secrets = [
    { name = "DB_PASSWORD", valueFrom = "${var.db_password_secret_arn}:password::" },
    { name = "SECRET_KEY", valueFrom = var.app_secret_key_arn },
  ]
}

# --- Web -----------------------------------------------------------------------

resource "aws_ecs_task_definition" "web" {
  family                   = "${var.name}-web"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.web_cpu
  memory                   = var.web_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.web.arn

  # Scratch space that disappears with the task.
  volume {
    name = "tmp"
  }

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name         = "web"
    image        = var.image
    essential    = true
    portMappings = [{ containerPort = 8000, protocol = "tcp" }]
    environment  = local.app_environment
    secrets      = local.app_secrets

    readonlyRootFilesystem = true
    mountPoints            = local.tmp_mount

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.web.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "web"
      }
    }
  }])
}

resource "aws_ecs_service" "web" {
  #checkov:skip=CKV_AWS_333:Public IP is needed to reach ECR and AWS APIs without a $33/month NAT Gateway. Inbound traffic is still blocked by the security group.
  name            = "web"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.web.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  # Wait 60 s after start-up before the load balancer's health checks count.
  health_check_grace_period_seconds = 60

  network_configuration {
    subnets          = var.public_subnet_ids
    security_groups  = [var.app_security_group_id]
    assign_public_ip = true # needed to pull images without a NAT Gateway
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = "web"
    container_port   = 8000
  }

  # If a new version fails its health checks, roll back automatically.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  propagate_tags = "SERVICE"

  # Autoscaling changes the number of tasks; Terraform shouldn't undo it.
  lifecycle {
    ignore_changes = [desired_count]
  }
}

# --- Worker + Gotenberg sidecar ----------------------------------------------

resource "aws_ecs_task_definition" "worker" {
  family                   = "${var.name}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.worker_cpu
  memory                   = var.worker_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.worker.arn

  #checkov:skip=CKV_AWS_336:The worker container is read-only; Gotenberg (LibreOffice) must write its profile and temp files, so it stays writable.

  volume {
    name = "tmp"
  }

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "worker"
      image     = var.image
      essential = true
      command   = ["celery", "-A", "app.worker.celery_app", "worker", "--loglevel=info", "--concurrency=2"]

      # On a Spot interruption, ECS sends SIGTERM. Celery then stops taking
      # new jobs and finishes the current one; give it the full 2 minutes.
      # A job cut off anyway is not lost: acks_late returns it to the queue.
      stopTimeout = 120
      environment = concat(local.app_environment, [{ name = "GOTENBERG_URL", value = "http://localhost:3000" }])
      secrets     = local.app_secrets

      readonlyRootFilesystem = true
      mountPoints            = local.tmp_mount

      # Start Gotenberg first. Containers in one Fargate task share
      # "localhost", so the worker reaches it at localhost:3000.
      dependsOn = [{ containerName = "gotenberg", condition = "START" }]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.worker.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "worker"
        }
      }
    },
    {
      name      = "gotenberg"
      image     = "gotenberg/gotenberg:8"
      essential = true

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.worker.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "gotenberg"
        }
      }
    },
  ])
}

resource "aws_ecs_service" "worker" {
  #checkov:skip=CKV_AWS_333:Public IP is needed to reach ECR and AWS APIs without a $33/month NAT Gateway. Inbound traffic is still blocked by the security group.
  name            = "worker"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = 1

  # FARGATE_SPOT by default (set worker_use_spot = false for on-demand).
  capacity_provider_strategy {
    capacity_provider = var.worker_use_spot ? "FARGATE_SPOT" : "FARGATE"
    weight            = 1
  }

  network_configuration {
    subnets          = var.public_subnet_ids
    security_groups  = [var.worker_security_group_id]
    assign_public_ip = true
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  propagate_tags = "SERVICE"

  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [aws_ecs_cluster_capacity_providers.this]
}
