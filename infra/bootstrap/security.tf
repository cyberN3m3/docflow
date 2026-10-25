# Account security baseline (Phase 8). Account-wide settings that a CIS
# benchmark / Prowler audit checks first. They live in the bootstrap layer
# because they must stay on between sessions. All of them are free, except
# CloudTrail's log storage, which costs cents.

locals {
  trail_name   = "docflow-account-trail"
  trail_bucket = "docflow-cloudtrail-${data.aws_caller_identity.current.account_id}"
  trail_arn    = "arn:aws:cloudtrail:${var.region}:${data.aws_caller_identity.current.account_id}:trail/${local.trail_name}"
}

# --- CloudTrail: who did what, in every region ---------------------------------
# Records every API call in the account (console clicks, CLI, Terraform,
# GitHub Actions) so any change can be traced to a person or role.

resource "aws_s3_bucket" "cloudtrail" {
  bucket = local.trail_bucket

  #checkov:skip=CKV_AWS_18:This is the audit log bucket; logging it would need another bucket, which would also need logging.
  #checkov:skip=CKV_AWS_144:Cross-region replication doubles the cost; versioning plus log file validation protect the logs.
  #checkov:skip=CKV_AWS_145:SSE-S3 encryption; a KMS key costs $1/month.
  #checkov:skip=CKV2_AWS_62:No process reacts to new log files.
}

resource "aws_s3_bucket_versioning" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Keep logs for a year, then delete them.
resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    id     = "expire-audit-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = 365
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.cloudtrail]
}

data "aws_iam_policy_document" "cloudtrail_bucket" {
  statement {
    sid       = "CloudTrailChecksTheBucket"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.cloudtrail.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid       = "CloudTrailWritesLogs"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = [aws_s3_bucket.cloudtrail.arn, "${aws_s3_bucket.cloudtrail.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  policy = data.aws_iam_policy_document.cloudtrail_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.cloudtrail]
}

resource "aws_cloudtrail" "account" {
  name           = local.trail_name
  s3_bucket_name = aws_s3_bucket.cloudtrail.id

  is_multi_region_trail         = true # an attacker could use any region
  include_global_service_events = true # IAM and sign-in events
  enable_log_file_validation    = true # proves the logs weren't edited

  #checkov:skip=CKV_AWS_35:Logs are encrypted with SSE-S3; a KMS key costs $1/month.
  #checkov:skip=CKV2_AWS_10:Sending the trail to CloudWatch Logs costs per GB; GuardDuty analyses CloudTrail directly.
  #checkov:skip=CKV_AWS_252:No SNS notification per log file; nothing consumes it.

  depends_on = [aws_s3_bucket_policy.cloudtrail]
}

# --- IAM Access Analyzer: finds anything shared outside the account -------------
resource "aws_accessanalyzer_analyzer" "account" {
  analyzer_name = "docflow-account"
  type          = "ACCOUNT"
}

# --- Block public S3 access for the whole account ------------------------------
# A second lock on top of each bucket's own setting: even a mistake in a
# future bucket can't make it public. OFF by default because this account
# also hosts other projects with public buckets (e.g. a static website),
# which this setting would take offline. DocFlow's own buckets block public
# access individually either way.
resource "aws_s3_account_public_access_block" "this" {
  count = var.block_public_s3_account_wide ? 1 : 0

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- Encrypt every new EBS disk by default ------------------------------------------
resource "aws_ebs_encryption_by_default" "this" {
  enabled = true
}

# --- Password rules for any IAM user ------------------------------------------------
# Day-to-day sign-in is through IAM Identity Center (SSO), so there are no
# IAM users. This policy makes sure any future one has a strong password.
resource "aws_iam_account_password_policy" "this" {
  minimum_password_length        = 14
  require_lowercase_characters   = true
  require_uppercase_characters   = true
  require_numbers                = true
  require_symbols                = true
  allow_users_to_change_password = true
  password_reuse_prevention      = 24
  max_password_age               = 90
}
