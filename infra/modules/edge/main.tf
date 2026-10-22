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
}

# Where the load balancer sends traffic: the web tasks' IP addresses on port 8000.
resource "aws_lb_target_group" "web" {
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
  enabled         = true
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
