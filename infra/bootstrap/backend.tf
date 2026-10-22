# Bootstrap state lives in the bucket it created.
# Bucket and region come from ../backend.hcl.
terraform {
  backend "s3" {
    key = "bootstrap/terraform.tfstate"
  }
}
