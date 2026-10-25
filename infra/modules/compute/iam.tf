# Two kinds of role, and why:
#   Execution role: used by ECS itself to pull the image, read the secrets
#                   into the container, and send logs. The app never sees it.
#   Task roles:     used by the app code (boto3) at run time. Each service
#                   gets only what it needs. No access keys anywhere.

data "aws_caller_identity" "current" {}

# Confused-deputy protection: ECS may assume these roles only for tasks in
# THIS account and region, so no other AWS customer can trick ECS into it.
data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }
}

# --- Execution role ------------------------------------------------------------

resource "aws_iam_role" "execution" {
  name               = "${var.name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "read_secrets" {
  statement {
    sid       = "ReadOnlyTheTwoAppSecrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.db_password_secret_arn, var.app_secret_key_arn]
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "read-app-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.read_secrets.json
}

# --- Shared: the files bucket ------------------------------------------------

data "aws_iam_policy_document" "files_bucket" {
  statement {
    sid       = "ObjectsInTheFilesBucketOnly"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${var.bucket_arn}/*"]
  }

  statement {
    # Lets S3 answer "not found" (404) instead of "access denied" (403)
    # when the app checks for a file that doesn't exist.
    sid       = "ListTheFilesBucket"
    actions   = ["s3:ListBucket"]
    resources = [var.bucket_arn]
  }
}

# --- Web task role: send jobs, never receive them ----------------------------

data "aws_iam_policy_document" "web_queue" {
  statement {
    sid       = "SendJobs"
    actions   = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
    resources = [var.queue_arn]
  }
}

resource "aws_iam_role" "web" {
  name               = "${var.name}-web-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy" "web_files" {
  name   = "files-bucket"
  role   = aws_iam_role.web.id
  policy = data.aws_iam_policy_document.files_bucket.json
}

resource "aws_iam_role_policy" "web_queue" {
  name   = "send-jobs"
  role   = aws_iam_role.web.id
  policy = data.aws_iam_policy_document.web_queue.json
}

# --- Worker task role: receive and finish jobs -------------------------------

data "aws_iam_policy_document" "worker_queue" {
  statement {
    sid = "ProcessJobs"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:SendMessage", # retries put the job back on the queue
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
    ]
    resources = [var.queue_arn]
  }
}

resource "aws_iam_role" "worker" {
  name               = "${var.name}-worker-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy" "worker_files" {
  name   = "files-bucket"
  role   = aws_iam_role.worker.id
  policy = data.aws_iam_policy_document.files_bucket.json
}

resource "aws_iam_role_policy" "worker_queue" {
  name   = "process-jobs"
  role   = aws_iam_role.worker.id
  policy = data.aws_iam_policy_document.worker_queue.json
}
