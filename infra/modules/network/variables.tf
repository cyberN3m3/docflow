variable "name" {
  description = "Prefix for resource names, e.g. docflow-demo."
  type        = string
}

variable "cidr_block" {
  description = "IP address range for the whole VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "How many Availability Zones (separate data centres) to use."
  type        = number
  default     = 2
}

variable "flow_log_retention_days" {
  description = "Days to keep VPC flow logs."
  type        = number
  default     = 7
}
