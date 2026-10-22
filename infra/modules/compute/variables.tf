variable "name" {
  description = "Prefix for resource names, e.g. docflow-demo."
  type        = string
}

variable "region" {
  type = string
}

variable "image" {
  description = "Full image reference, e.g. <account>.dkr.ecr.us-east-1.amazonaws.com/docflow:abc1234."
  type        = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "app_security_group_id" {
  type = string
}

variable "worker_security_group_id" {
  type = string
}

variable "target_group_arn" {
  description = "Load balancer target group for the web service."
  type        = string
}

variable "bucket_name" {
  type = string
}

variable "bucket_arn" {
  type = string
}

variable "queue_name" {
  type = string
}

variable "queue_url" {
  type = string
}

variable "queue_arn" {
  type = string
}

variable "db_address" {
  type = string
}

variable "db_name" {
  type = string
}

variable "db_username" {
  type = string
}

variable "db_password_secret_arn" {
  description = "RDS-managed secret; the app reads its \"password\" key."
  type        = string
}

variable "app_secret_key_arn" {
  type = string
}

variable "web_cpu" {
  type    = number
  default = 256 # 0.25 vCPU
}

variable "web_memory" {
  type    = number
  default = 512 # MB
}

variable "worker_cpu" {
  type    = number
  default = 1024 # 1 vCPU, shared by the worker and Gotenberg
}

variable "worker_memory" {
  type    = number
  default = 2048 # MB; Gotenberg runs LibreOffice, which needs room
}

variable "log_retention_days" {
  type    = number
  default = 7
}
