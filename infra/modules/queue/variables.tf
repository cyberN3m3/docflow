variable "name" {
  description = "Prefix for resource names, e.g. docflow-demo."
  type        = string
}

variable "max_receive_count" {
  description = "How many times a job may fail before it moves to the dead-letter queue."
  type        = number
  default     = 3
}
