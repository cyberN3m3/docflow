# The way in: CloudFront (HTTPS) -> Application Load Balancer -> web tasks.

# --- Secret header -----------------------------------------------------------
# CloudFront adds this header to every request it forwards. The load
# balancer only forwards requests that carry it, so nobody can skip
# CloudFront by calling the load balancer directly. This is a second lock on
# top of the security group, which only admits CloudFront's IP ranges.
resource "random_password" "origin_verify" {
  length  = 48
  special = false
}

locals {
  origin_header = "X-Origin-Verify"
}

# --- Application Load Balancer -----------------------------------------------

resource "aws_lb" "this" {
  name               = "${var.name}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [var.alb_security_group_id]
  subnets            = var.public_subnet_ids

  # Reject requests with malformed headers (a common attack technique).
  drop_invalid_header_fields = true
  idle_timeout               = 120

  # Demo setting so the daily destroy works. Production would set true.
  enable_deletion_protection = false

  # Accepted risks (see docs/security.md):
  #checkov:skip=CKV_AWS_150:Deletion protection is off so the environment can be destroyed after every session. Production: on.
  #checkov:skip=CKV_AWS_91:Access logs skipped to save cost; WAF logs blocked requests and CloudWatch has ALB metrics. Production: on.
  #checkov:skip=CKV2_AWS_28:The ALB only accepts CloudFront traffic (prefix list + secret header), and WAF is attached to CloudFront.
  #checkov:skip=CKV2_AWS_20:Viewers are redirected to HTTPS by CloudFront; the ALB never receives viewer traffic directly.
}

# Where the load balancer sends traffic: the web tasks' IP addresses on port 8000.
resource "aws_lb_target_group" "web" {
  #checkov:skip=CKV_AWS_378:ALB-to-task traffic stays inside the VPC, between security groups that only allow each other.
  name        = "${var.name}-web"
  port        = 8000
  protocol    = "HTTP"
  target_type = "ip" # Fargate tasks are registered by IP address
  vpc_id      = var.vpc_id

  # Give in-flight requests 30 s to finish when a task is replaced.
  deregistration_delay = 30

  health_check {
    path                = var.health_check_path
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
  }
}

# Listener: by default, refuse everything...
resource "aws_lb_listener" "http" {
  #checkov:skip=CKV_AWS_2:HTTPS on the ALB needs a custom domain and certificate; viewers get HTTPS from CloudFront. Production: CloudFront VPC origin or HTTPS origin.
  #checkov:skip=CKV_AWS_103:Same reason as CKV_AWS_2: no TLS listener without a custom domain.
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Direct access is not allowed."
      status_code  = "403"
    }
  }
}

# ...and forward only requests that came through CloudFront.
resource "aws_lb_listener_rule" "from_cloudfront" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 1

  condition {
    http_header {
      http_header_name = local.origin_header
      values           = [random_password.origin_verify.result]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

# --- CloudFront ----------------------------------------------------------------

# AWS-managed policies, looked up by name.
data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

data "aws_cloudfront_response_headers_policy" "security" {
  name = "Managed-SecurityHeadersPolicy"
}

resource "aws_cloudfront_distribution" "this" {
  #checkov:skip=CKV_AWS_174:The free *.cloudfront.net certificate can't set a minimum TLS version. A custom domain with ACM would allow TLSv1.2_2021.
  #checkov:skip=CKV2_AWS_42:Same reason: no custom domain in this demo.
  #checkov:skip=CKV_AWS_86:Access logs skipped to save cost; WAF logs blocked requests.
  #checkov:skip=CKV_AWS_374:DocFlow serves users worldwide, so there is no geographic restriction.
  #checkov:skip=CKV_AWS_310:Only one origin exists; failover would need a second region (see docs/disaster-recovery.md).
  #checkov:skip=CKV2_AWS_47:Log4j protection (KnownBadInputs) is on. The check also wants the anonymous-IP list, which would block VPN users and cloud-hosted clients, including the CI smoke test.
  #checkov:skip=CKV_AWS_305:Not applicable: the origin is a dynamic app, not an S3 website.
  enabled         = true
  web_acl_id      = aws_wafv2_web_acl.this.arn
  comment         = "${var.name} DocFlow"
  is_ipv6_enabled = true

  # Edge locations in North America, Europe, Asia, the Middle East and
  # Africa (including Lagos), but not the most expensive regions.
  price_class = "PriceClass_200"

  origin {
    origin_id   = "alb"
    domain_name = aws_lb.this.dns_name

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    custom_header {
      name  = local.origin_header
      value = random_password.origin_verify.result
    }
  }

  # App pages and uploads: never cached, everything forwarded (cookies,
  # form data), and plain HTTP visitors are redirected to HTTPS.
  default_cache_behavior {
    target_origin_id           = "alb"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security.id
  }

  # CSS and other static files: cached at the edge, close to users.
  ordered_cache_behavior {
    path_pattern               = "/static/*"
    target_origin_id           = "alb"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # Free HTTPS on the *.cloudfront.net address; no domain needed.
  viewer_certificate {
    cloudfront_default_certificate = true
  }
}
