variable "region" {
  description = "AWS region for the long-lived resources."
  type        = string
  default     = "us-east-1"
}

variable "github_owner" {
  description = "GitHub account that owns the repo. Case-sensitive: must match GitHub exactly."
  type        = string
  default     = "cyberN3m3"
}

variable "github_owner_id" {
  description = "Immutable numeric ID of the owner (GitHub API: repos/{owner}/{repo} -> owner.id)."
  type        = string
  default     = "239107129"
}

variable "github_repo" {
  type    = string
  default = "docflow"
}

variable "github_repo_id" {
  description = "Immutable numeric ID of the repo (GitHub API: repos/{owner}/{repo} -> id)."
  type        = string
  default     = "1428678851"
}

variable "environment_name" {
  description = "Prefix used by the main environment's resources (project-environment)."
  type        = string
  default     = "docflow-demo"
}

variable "block_public_s3_account_wide" {
  description = "Block public access for every S3 bucket in the account. Turn on once no other project needs a public bucket."
  type        = bool
  default     = false
}
