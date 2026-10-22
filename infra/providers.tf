provider "aws" {
  region = var.region

  # Added to every resource Terraform creates. Phase 9's cost report
  # filters on these tags.
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
