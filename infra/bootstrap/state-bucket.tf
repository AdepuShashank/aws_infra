# ------------------------------------------------------------------ state bucket ---
# Terraform remote state: versioning + SSE-KMS + no public access + TLS only.
# Layer keys are <env>/<layer>/terraform.tfstate (see docs/state-layout.md).

resource "aws_s3_bucket" "state" {
  bucket        = local.state_bucket_name
  force_destroy = var.env == "qa" # qa is the disposable environment
  tags          = local.standard_tags

  lifecycle {
    # Renaming or recreating the bucket would strand every environment's state.
    precondition {
      condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", local.state_bucket_name))
      error_message = "state bucket name must be a valid, globally unique S3 bucket name."
    }
  }
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.state.arn
      sse_algorithm     = "aws:kms"
    }

    # One KMS grant per object instead of per API call.
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-stale-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.state_noncurrent_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = var.state_abort_multipart_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

# --------------------------------------------------------------------------- policy ---

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # Bucket-level administration is deliberately NOT delegated to CI. The
  # apply role may manage state objects (Terraform needs Put/Delete for the
  # S3 lockfile) but must never be able to delete the bucket or rewrite the
  # bucket policy, which would strand every environment's state.
  dynamic "statement" {
    for_each = var.create_github_oidc ? [1] : []

    content {
      sid    = "DenyBucketAdministrationToCiRoles"
      effect = "Deny"
      actions = [
        "s3:DeleteBucket",
        "s3:PutBucketPolicy",
        "s3:PutBucketAcl",
        "s3:PutBucketTagging",
        "s3:PutBucketVersioning",
        "s3:PutBucketOwnershipControls",
        "s3:PutLifecycleConfiguration",
        "s3:PutEncryptionConfiguration",
      ]
      resources = [aws_s3_bucket.state.arn]

      principals {
        type        = "AWS"
        identifiers = [local.plan_role_arn, local.apply_role_arn]
      }
    }
  }

  # Operator / bootstrap-teardown access to state objects.
  statement {
    sid    = "AllowStateObjectAccessForOperators"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.state_admin.arn]
    }
  }

  # CI roles: full control over state objects only (Terraform needs DeleteObject
  # to release the S3 lockfile and to rotate state).
  dynamic "statement" {
    for_each = var.create_github_oidc ? [1] : []

    content {
      sid    = "AllowCiRolesToManageStateObjects"
      effect = "Allow"
      actions = [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
      ]
      resources = [
        aws_s3_bucket.state.arn,
        "${aws_s3_bucket.state.arn}/*",
      ]

      principals {
        type        = "AWS"
        identifiers = [local.plan_role_arn, local.apply_role_arn]
      }
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}