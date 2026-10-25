# One screen showing DocFlow's health, top to bottom in the order a request
# travels: edge -> load balancer -> app -> queue and worker -> database.

locals {
  alb    = ["LoadBalancer", var.alb_arn_suffix]
  tg     = ["TargetGroup", var.target_group_arn_suffix, "LoadBalancer", var.alb_arn_suffix]
  web    = ["ClusterName", var.cluster_name, "ServiceName", var.web_service_name]
  worker = ["ClusterName", var.cluster_name, "ServiceName", var.worker_service_name]
  db     = ["DBInstanceIdentifier", var.db_identifier]

  graph = { view = "timeSeries", stacked = false, region = var.region, period = 60 }

  widgets = [
    {
      type = "alarm", x = 0, y = 0, width = 24, height = 3
      properties = {
        title = "Alarms"
        alarms = [
          aws_cloudwatch_metric_alarm.no_healthy_web.arn,
          aws_cloudwatch_metric_alarm.cloudfront_5xx.arn,
          aws_cloudwatch_metric_alarm.app_5xx.arn,
          aws_cloudwatch_metric_alarm.slow_responses.arn,
          aws_cloudwatch_metric_alarm.jobs_waiting.arn,
          aws_cloudwatch_metric_alarm.dead_letters.arn,
          aws_cloudwatch_metric_alarm.jobs_failing.arn,
          aws_cloudwatch_metric_alarm.web_cpu.arn,
          aws_cloudwatch_metric_alarm.worker_memory.arn,
          aws_cloudwatch_metric_alarm.db_cpu.arn,
          aws_cloudwatch_metric_alarm.db_storage.arn,
          aws_cloudwatch_metric_alarm.waf_blocking.arn,
        ]
      }
    },
    {
      type = "metric", x = 0, y = 3, width = 8, height = 6
      properties = merge(local.graph, {
        title = "Requests and errors"
        stat  = "Sum"
        metrics = [
          concat(["AWS/ApplicationELB", "RequestCount"], local.alb),
          concat(["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count"], local.tg, [{ color = "#d62728" }]),
          concat(["AWS/ApplicationELB", "HTTPCode_Target_4XX_Count"], local.tg),
        ]
      })
    },
    {
      type = "metric", x = 8, y = 3, width = 8, height = 6
      properties = merge(local.graph, {
        title = "Response time (seconds)"
        metrics = [
          concat(["AWS/ApplicationELB", "TargetResponseTime"], local.tg, [{ stat = "p50", label = "p50" }]),
          concat(["AWS/ApplicationELB", "TargetResponseTime"], local.tg, [{ stat = "p95", label = "p95" }]),
        ]
      })
    },
    {
      type = "metric", x = 16, y = 3, width = 8, height = 6
      properties = merge(local.graph, {
        title = "WAF: allowed vs blocked"
        stat  = "Sum"
        metrics = [
          ["AWS/WAFV2", "AllowedRequests", "WebACL", var.web_acl_name, "Rule", "ALL"],
          ["AWS/WAFV2", "BlockedRequests", "WebACL", var.web_acl_name, "Rule", "ALL", { color = "#d62728" }],
        ]
      })
    },
    {
      type = "metric", x = 0, y = 9, width = 8, height = 6
      properties = merge(local.graph, {
        title = "Web and worker CPU %"
        stat  = "Average"
        metrics = [
          concat(["AWS/ECS", "CPUUtilization"], local.web, [{ label = "web" }]),
          concat(["AWS/ECS", "CPUUtilization"], local.worker, [{ label = "worker" }]),
        ]
      })
    },
    {
      type = "metric", x = 8, y = 9, width = 8, height = 6
      properties = merge(local.graph, {
        title = "Web and worker memory %"
        stat  = "Maximum"
        metrics = [
          concat(["AWS/ECS", "MemoryUtilization"], local.web, [{ label = "web" }]),
          concat(["AWS/ECS", "MemoryUtilization"], local.worker, [{ label = "worker" }]),
        ]
      })
    },
    {
      type = "metric", x = 16, y = 9, width = 8, height = 6
      properties = merge(local.graph, {
        title = "Healthy web tasks"
        stat  = "Minimum"
        metrics = [
          concat(["AWS/ApplicationELB", "HealthyHostCount"], local.tg),
          concat(["AWS/ApplicationELB", "UnHealthyHostCount"], local.tg, [{ color = "#d62728" }]),
        ]
      })
    },
    {
      type = "metric", x = 0, y = 15, width = 8, height = 6
      properties = merge(local.graph, {
        title = "Job queue"
        stat  = "Maximum"
        metrics = [
          ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", var.queue_name, { label = "waiting" }],
          ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", var.dead_letter_queue_name, { label = "dead-lettered", color = "#d62728" }],
          ["AWS/SQS", "ApproximateAgeOfOldestMessage", "QueueName", var.queue_name, { label = "oldest (s)", yAxis = "right" }],
        ]
      })
    },
    {
      type = "metric", x = 8, y = 15, width = 8, height = 6
      properties = merge(local.graph, {
        title = "Failed conversions (from worker logs)"
        stat  = "Sum"
        metrics = [
          ["DocFlow", "JobsFailed", { color = "#d62728" }],
        ]
      })
    },
    {
      type = "metric", x = 16, y = 15, width = 8, height = 6
      properties = merge(local.graph, {
        title = "Database"
        metrics = [
          concat(["AWS/RDS", "CPUUtilization"], local.db, [{ label = "CPU %" }]),
          concat(["AWS/RDS", "DatabaseConnections"], local.db, [{ label = "connections", yAxis = "right" }]),
        ]
      })
    },
  ]
}

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = var.name
  dashboard_body = jsonencode({ widgets = local.widgets })
}
