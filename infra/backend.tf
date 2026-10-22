# State lives in the S3 bucket created by infra/bootstrap.
# Bucket and region come from backend.hcl (not committed; see backend.hcl.example):
#   terraform init -backend-config=backend.hcl
terraform {
  backend "s3" {
    key = "docflow/demo/terraform.tfstate"
  }
}
