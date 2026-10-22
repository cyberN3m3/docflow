variable "name" {
  description = "Prefix for resource names, e.g. docflow-demo."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  description = "Public subnets the load balancer lives in."
  type        = list(string)
}

variable "alb_security_group_id" {
  description = "Security group that only lets CloudFront reach the load balancer."
  type        = string
}

variable "health_check_path" {
  type    = string
  default = "/healthz"
}
