# S3 bucket for uploaded and converted files. Replaces the local uploads
# volume on the legacy server.

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "files" {
  bucket = "${var.name}-files-${data.aws_caller_identity.current.account_id}"

  #checkov:skip=CKV_AWS_18:Access is recorded by the app (who downloads which job) and CloudTrail; S3 access logs would add a second bucket.
  #checkov:skip=CKV_AWS_144:Cross-region replication doubles storage cost; versioning protects against deletion (see docs/disaster-recovery.md).
  #checkov:skip=CKV_AWS_145:SSE-S3 encryption; a KMS key costs $1/month plus per-request fees.
  #checkov:skip=CKV2_AWS_62:Jobs are queued through SQS by the app, not by S3 events.

  # Lets `terraform destroy` empty and delete the bucket. Fine for a demo
  # environment that is rebuilt daily; production would set this to false.
  force_destroy = true
}

# Keep previous versions so deleted or overwritten files can be recovered.
resource "aws_s3_bucket_versioning" "files" {
  bucket = aws_s3_bucket.files.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "files" {
  bucket = aws_s3_bucket.files.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "files" {
  bucket = aws_s3_bucket.files.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "files" {
  bucket = aws_s3_bucket.files.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Refuse any request that isn't over HTTPS.
data "aws_iam_policy_document" "files_tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = [
      aws_s3_bucket.files.arn,
      "${aws_s3_bucket.files.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "files" {
  bucket = aws_s3_bucket.files.id
  policy = data.aws_iam_policy_document.files_tls_only.json

  depends_on = [aws_s3_bucket_public_access_block.files]
}

resource "aws_s3_bucket_lifecycle_configuration" "files" {
  bucket = aws_s3_bucket.files.id

  # Uploaded originals are only needed until they are converted.
  rule {
    id     = "expire-uploaded-inputs"
    status = "Enabled"

    filter {
      prefix = "inputs/"
    }

    expiration {
      days = var.input_retention_days
    }
  }

  # Old versions are kept for recovery, but not forever.
  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.files]
}
