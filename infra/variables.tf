variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name, used in resource names and tags."
  type        = string
  default     = "docflow"
}

variable "environment" {
  description = "Environment name, used in resource names and tags."
  type        = string
  default     = "demo"
}
