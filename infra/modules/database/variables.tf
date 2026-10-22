variable "name" {
  description = "Prefix for resource names, e.g. docflow-demo."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets the database lives in."
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group that controls who can reach the database."
  type        = string
}

variable "instance_class" {
  description = "Database size."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Disk size in GB."
  type        = number
  default     = 20
}
