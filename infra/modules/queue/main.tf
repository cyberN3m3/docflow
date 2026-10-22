# SQS job queue for conversions. Replaces Redis on the legacy server.

# "Problem jobs" tray: messages that failed too many times end up here.
resource "aws_sqs_queue" "dead_letter" {
  name                      = "${var.name}-jobs-dlq"
  message_retention_seconds = 1209600 # 14 days, the maximum
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "jobs" {
  name = "${var.name}-jobs"

  # A worker has 15 minutes to finish a job before SQS hands it to another.
  visibility_timeout_seconds = 900

  # Long polling: workers wait up to 20 s for a message instead of asking
  # repeatedly, which means fewer requests and a lower bill.
  receive_wait_time_seconds = 20

  sqs_managed_sse_enabled = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dead_letter.arn
    maxReceiveCount     = var.max_receive_count
  })
}
