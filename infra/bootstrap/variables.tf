variable "region" {
  description = "AWS region for the long-lived resources."
  type        = string
  default     = "us-east-1"
}

variable "github_repository" {
  description = "owner/name of the GitHub repo allowed to deploy. Case-sensitive: must match GitHub exactly."
  type        = string
  default     = "cyberN3m3/docflow"
}

variable "environment_name" {
  description = "Prefix used by the main environment's resources (project-environment)."
  type        = string
  default     = "docflow-demo"
}
