variable "name" {
  description = "Prefix for resource names, e.g. docflow-demo."
  type        = string
}

variable "input_retention_days" {
  description = "Days to keep uploaded original files before deleting them."
  type        = number
  default     = 7
}
