# Long-lived resources that must survive every `terraform destroy` of the
# main environment. Applied once, then rarely touched.

data "aws_caller_identity" "current" {}

locals {
  # Bucket names are global across all AWS accounts, so the account ID
  # makes this one unique.
  state_bucket = "docflow-tfstate-${data.aws_caller_identity.current.account_id}"
}

# --- Terraform state bucket --------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket

  # Terraform refuses to delete this bucket, even with `terraform destroy`.
  lifecycle {
    prevent_destroy = true
  }
}

# Keep every previous version of the state file, so a bad change can be undone.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Encrypt everything stored in the bucket.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Nobody on the internet can ever read this bucket.
resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Disable old-style ACLs; access is controlled only by IAM and bucket policy.
resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Refuse any request that isn't over HTTPS.
data "aws_iam_policy_document" "state_tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_tls_only.json

  # The public access block must exist first, or AWS may reject the policy.
  depends_on = [aws_s3_bucket_public_access_block.state]
}

# Old state versions are only needed for a while; delete them after 90 days
# so storage costs stay at a few cents.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}