# Monitoring and alerting (Phase 10): CloudWatch alarms, email alerts and
# event-driven notifications. Each alarm answers one question an on-call
# engineer would ask; docs/operations.md says what to do when it fires.

data "aws_caller_identity" "current" {}

# --- Where alerts go -----------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name = "${var.name}-alerts"

  #checkov:skip=CKV_AWS_26:CloudWatch alarms can't publish to a topic encrypted with the AWS-managed SNS key, and a customer-managed key costs $1/month. Alerts contain no customer data.
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alert_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email # AWS sends a confirmation email first
}

# Only CloudWatch alarms and EventBridge rules from this account may publish.
data "aws_iam_policy_document" "alerts" {
  statement {
    sid       = "AlarmsAndEventsFromThisAccount"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com", "events.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts.json
}

locals {
  alarm_actions = [aws_sns_topic.alerts.arn]

  alb_dims = { LoadBalancer = var.alb_arn_suffix }
  tg_dims  = { LoadBalancer = var.alb_arn_suffix, TargetGroup = var.target_group_arn_suffix }
}

# --- Users: is the site up and fast? -----------------------------------------------

# Outside-in: what visitors see at the edge (any cause, including CloudFront).
resource "aws_cloudwatch_metric_alarm" "cloudfront_5xx" {
  alarm_name          = "${var.name}-site-errors"
  alarm_description   = "More than 5% of requests to the site are failing (5xx at CloudFront)."
  namespace           = "AWS/CloudFront"
  metric_name         = "5xxErrorRate"
  dimensions          = { DistributionId = var.cloudfront_distribution_id, Region = "Global" }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# No healthy web task behind the load balancer = the site is down.
resource "aws_cloudwatch_metric_alarm" "no_healthy_web" {
  alarm_name          = "${var.name}-site-down"
  alarm_description   = "No healthy web task behind the load balancer: the site is down."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = local.tg_dims
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "app_5xx" {
  alarm_name          = "${var.name}-app-errors"
  alarm_description   = "The app returned more than 10 server errors (5xx) in 5 minutes."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions          = local.tg_dims
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "slow_responses" {
  alarm_name          = "${var.name}-slow-responses"
  alarm_description   = "95% of requests are slower than 2 seconds (p95 latency)."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  dimensions          = local.tg_dims
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 2
  threshold           = 2
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}

# --- Jobs: are conversions getting done? ----------------------------------------

resource "aws_cloudwatch_metric_alarm" "jobs_waiting" {
  alarm_name          = "${var.name}-jobs-stuck"
  alarm_description   = "A job has waited more than 10 minutes in the queue: workers are down or overwhelmed."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  dimensions          = { QueueName = var.queue_name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 600
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "dead_letters" {
  alarm_name          = "${var.name}-jobs-dead-lettered"
  alarm_description   = "A job failed 3 times and was moved to the dead-letter queue. Inspect it."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = var.dead_letter_queue_name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}

# App-level metric from the worker's logs: each "job <id> failed:" line.
resource "aws_cloudwatch_log_metric_filter" "jobs_failed" {
  name           = "${var.name}-jobs-failed"
  log_group_name = var.worker_log_group_name
  pattern        = "\"job\" \"failed:\""

  metric_transformation {
    name          = "JobsFailed"
    namespace     = "DocFlow"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "jobs_failing" {
  alarm_name          = "${var.name}-jobs-failing"
  alarm_description   = "5 or more conversions failed in 15 minutes."
  namespace           = "DocFlow"
  metric_name         = aws_cloudwatch_log_metric_filter.jobs_failed.metric_transformation[0].name
  statistic           = "Sum"
  period              = 900
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}

# --- Capacity: running out of room? -------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "web_cpu" {
  alarm_name          = "${var.name}-web-cpu-high"
  alarm_description   = "Web CPU above 85% for 15 minutes, despite autoscaling (which starts at 60%)."
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  dimensions          = { ClusterName = var.cluster_name, ServiceName = var.web_service_name }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "worker_memory" {
  alarm_name          = "${var.name}-worker-memory-high"
  alarm_description   = "Worker task memory above 90%: LibreOffice may be killed for running out of memory."
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  dimensions          = { ClusterName = var.cluster_name, ServiceName = var.worker_service_name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 90
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "db_cpu" {
  alarm_name          = "${var.name}-db-cpu-high"
  alarm_description   = "Database CPU above 80% for 15 minutes."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = var.db_identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "db_storage" {
  alarm_name          = "${var.name}-db-storage-low"
  alarm_description   = "Less than 2 GB of database storage left."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = var.db_identifier }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 2 * 1024 * 1024 * 1024
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}

# --- Security: under attack? ---------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "waf_blocking" {
  alarm_name          = "${var.name}-waf-blocking-spike"
  alarm_description   = "The WAF blocked more than 200 requests in 5 minutes: likely an attack or a scan."
  namespace           = "AWS/WAFV2"
  metric_name         = "BlockedRequests"
  dimensions          = { WebACL = var.web_acl_name, Rule = "ALL" }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 200
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}
