# AWS WAF in front of CloudFront: filters attacks before they reach the app.
#
# Rules are checked in priority order (lowest first):
#   1. Login brute force: one IP can try /login at most 100 times in 5 minutes.
#   2. Flood protection: one IP can make at most 2,000 requests in 5 minutes.
#   3. AWS IP reputation list: known bots, scanners and attack sources.
#   4. Known bad inputs: Log4Shell and other exploit payloads.
#   5. AWS common rule set (OWASP Top 10 style), tuned for file uploads.
#
# A web ACL for CloudFront must live in us-east-1, which is where this
# environment runs.

resource "aws_wafv2_web_acl" "this" {
  name        = "${var.name}-edge"
  description = "DocFlow: rate limits and AWS managed rules"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "login-rate-limit"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit                 = var.login_rate_limit
        evaluation_window_sec = 300
        aggregate_key_type    = "IP"

        scope_down_statement {
          byte_match_statement {
            search_string         = "/login"
            positional_constraint = "STARTS_WITH"

            field_to_match {
              uri_path {}
            }

            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-login-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "ip-rate-limit"
    priority = 2

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit                 = var.ip_rate_limit
        evaluation_window_sec = 300
        aggregate_key_type    = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-ip-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-ip-reputation"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesAmazonIpReputationList"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-known-bad-inputs"
    priority = 4

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-common"
    priority = 5

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"

        # DocFlow's job is accepting file uploads. These two rules would block
        # them: one blocks any body over 8 KB, the other can match random bytes
        # inside a binary .docx or image. They are set to "count" (logged in
        # metrics, not blocked). The app itself limits uploads to 20 MB and
        # checks file types.
        rule_action_override {
          name = "SizeRestrictions_BODY"

          action_to_use {
            count {}
          }
        }

        rule_action_override {
          name = "CrossSiteScripting_BODY"

          action_to_use {
            count {}
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-common"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-edge"
    sampled_requests_enabled   = true
  }
}

# --- WAF logs: blocked requests only -------------------------------------------
# Logging every allowed request would cost money and tell us little. Blocked
# requests are the interesting ones: who attacked, and which rule stopped them.

resource "aws_cloudwatch_log_group" "waf" {
  # WAF requires the "aws-waf-logs-" prefix.
  name              = "aws-waf-logs-${var.name}"
  retention_in_days = 30

  #checkov:skip=CKV_AWS_158:Encrypted with CloudWatch's AWS-managed key. A customer-managed KMS key costs $1/month and adds nothing for this data.
  #checkov:skip=CKV_AWS_338:30 days is enough to investigate an incident in a demo; 1-year retention is a production compliance requirement.
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "waf_logs" {
  statement {
    sid       = "AllowWafToWriteLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.waf.arn}:*"]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "waf" {
  policy_name     = "${var.name}-waf-logs"
  policy_document = data.aws_iam_policy_document.waf_logs.json
}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  resource_arn            = aws_wafv2_web_acl.this.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]

  logging_filter {
    default_behavior = "DROP"

    filter {
      behavior    = "KEEP"
      requirement = "MEETS_ANY"

      condition {
        action_condition {
          action = "BLOCK"
        }
      }
    }
  }

  depends_on = [aws_cloudwatch_log_resource_policy.waf]
}
