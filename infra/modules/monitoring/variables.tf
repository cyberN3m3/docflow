variable "name" {
  description = "Prefix for resource names, e.g. docflow-demo."
  type        = string
}

variable "region" {
  type = string
}

variable "alert_email" {
  description = "Email address that receives alarms. Empty = no subscription."
  type        = string
  default     = ""
}

variable "alb_arn_suffix" {
  type = string
}

variable "target_group_arn_suffix" {
  type = string
}

variable "cloudfront_distribution_id" {
  type = string
}

variable "web_acl_name" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "web_service_name" {
  type = string
}

variable "worker_service_name" {
  type = string
}

variable "worker_log_group_name" {
  type = string
}

variable "db_identifier" {
  type = string
}

variable "queue_name" {
  type = string
}

variable "dead_letter_queue_name" {
  type = string
}
