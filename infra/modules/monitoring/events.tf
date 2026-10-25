# Event-driven alerts: things that happen once, rather than a metric crossing
# a threshold. EventBridge matches the event and emails a readable summary.

locals {
  event_rules = {
    deploy-failed = {
      description = "An ECS deployment failed and was rolled back."
      pattern = jsonencode({
        source        = ["aws.ecs"]
        "detail-type" = ["ECS Deployment State Change"]
        # Deployment events carry the service's ARN, not the cluster's.
        resources = [{
          prefix = "arn:aws:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:service/${var.cluster_name}/"
        }]
        detail = {
          eventName = ["SERVICE_DEPLOYMENT_FAILED"]
        }
      })
      paths    = { reason = "$.detail.reason", resource = "$.resources[0]" }
      template = "\"DocFlow deployment FAILED and was rolled back. Service: <resource>. Reason: <reason>\""
    }

    spot-interruption = {
      description = "AWS reclaimed a Fargate Spot worker; ECS starts a replacement."
      pattern = jsonencode({
        source        = ["aws.ecs"]
        "detail-type" = ["ECS Task State Change"]
        detail = {
          clusterArn = [{ suffix = "/${var.cluster_name}" }]
          stopCode   = ["SpotInterruption"]
        }
      })
      paths    = { task = "$.detail.taskArn" }
      template = "\"DocFlow: a Spot worker was interrupted (task <task>). ECS is starting a replacement; jobs in progress return to the queue.\""
    }

    guardduty-finding = {
      description = "GuardDuty found a high-severity threat."
      pattern = jsonencode({
        source        = ["aws.guardduty"]
        "detail-type" = ["GuardDuty Finding"]
        detail = {
          severity = [{ numeric = [">=", 7] }]
        }
      })
      paths    = { type = "$.detail.type", severity = "$.detail.severity", title = "$.detail.title" }
      template = "\"GuardDuty HIGH finding (severity <severity>): <type>. <title>. Check GuardDuty in the AWS console.\""
    }

    root-sign-in = {
      description = "Someone signed in to the console as the root user."
      pattern = jsonencode({
        source        = ["aws.signin"]
        "detail-type" = ["AWS Console Sign In via CloudTrail"]
        detail = {
          userIdentity = { type = ["Root"] }
        }
      })
      paths    = { ip = "$.detail.sourceIPAddress", result = "$.detail.responseElements.ConsoleLogin" }
      template = "\"ROOT USER console sign-in from <ip> (result: <result>). If this wasn't you, secure the account now.\""
    }
  }
}

resource "aws_cloudwatch_event_rule" "alerts" {
  for_each = local.event_rules

  name          = "${var.name}-${each.key}"
  description   = each.value.description
  event_pattern = each.value.pattern
}

resource "aws_cloudwatch_event_target" "alerts" {
  for_each = local.event_rules

  rule = aws_cloudwatch_event_rule.alerts[each.key].name
  arn  = aws_sns_topic.alerts.arn

  input_transformer {
    input_paths    = each.value.paths
    input_template = each.value.template
  }
}
