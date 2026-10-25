output "target_group_arn" {
  value = aws_lb_target_group.web.arn

  # ECS can only attach a service to a target group that is already wired
  # to the load balancer, so hand this out only once the rule exists.
  depends_on = [aws_lb_listener_rule.from_cloudfront]
}

output "alb_dns_name" {
  description = "The load balancer's own address. Direct visits should be refused."
  value       = aws_lb.this.dns_name
}

output "cloudfront_domain_name" {
  value = aws_cloudfront_distribution.this.domain_name
}

output "alb_arn_suffix" {
  description = "Used by CloudWatch metrics in Phase 10."
  value       = aws_lb.this.arn_suffix
}

output "target_group_arn_suffix" {
  description = "Used by CloudWatch metrics in Phase 10."
  value       = aws_lb_target_group.web.arn_suffix
}

output "web_acl_name" {
  description = "Used by CloudWatch metrics in Phase 10."
  value       = aws_wafv2_web_acl.this.name
}
