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

variable "login_rate_limit" {
  description = "Most requests one IP address may send to /login in 5 minutes."
  type        = number
  default     = 100
}

variable "ip_rate_limit" {
  description = "Most requests one IP address may send in 5 minutes."
  type        = number
  default     = 2000
}
