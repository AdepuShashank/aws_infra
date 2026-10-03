# ---------------------------------------------------------------------------
# etcd backup bucket
# ---------------------------------------------------------------------------
# Created here, not in 70-backups, because Phase 4 is the first layer that needs
# it: the control plane's snapshot timer uploads to this bucket on first boot, and
# the upload fails if the bucket does not exist. 70-backups will reference this
# bucket's name rather than create a second one, so there is exactly one bucket
# per environment.
#
# etcd snapshots contain every Secret and ConfigMap in the cluster in plaintext.
# That is why access is denied at the account level and granted only through the
# node role: nothing else in the account, including a future human, can list or
# read these objects without an explicit IAM grant.

resource "aws_s3_bucket" "etcd_backups" {
  bucket = var.etcd_backup_bucket_name

  tags = merge(local.resource_tags["etcd_backup_bucket"], {
    Name = var.etcd_backup_bucket_name
  })
}

resource "aws_s3_bucket_public_access_block" "etcd_backups" {
  bucket                  = aws_s3_bucket.etcd_backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "etcd_backups" {
  bucket = aws_s3_bucket.etcd_backups.id

  # SSE-KMS rather than SSE-S3: the snapshots are cluster state including
  # secrets, and the spec asks for CMK-backed encryption everywhere.
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.ebs_kms_key_arn
    }

    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "etcd_backups" {
  bucket = aws_s3_bucket.etcd_backups.id

  # Versioning is on despite the lifecycle expiring objects: a bad snapshot that
  # is deleted can be recovered within its grace window.
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_ownership_controls" "etcd_backups" {
  bucket = aws_s3_bucket.etcd_backups.id

  rule {
    # BucketOwnerEnforced disables ACLs entirely. The snapshot uploader runs as
    # the node role with bucket-owner-full-control s3:x-amz-acl omitted, so this
    # is the setting where uploads succeed and no ACL can widen access.
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "etcd_backups" {
  bucket = aws_s3_bucket.etcd_backups.id

  rule {
    id     = "etcd-snapshot-expiry"
    status = "Enabled"

    # Noncurrent versions are dropped first: with versioning on, a snapshot that
    # gets overwritten would otherwise keep its old versions alive forever and the
    # prefix filter would never reclaim the space.
    filter {
      prefix = "etcd-"
    }

    expiration {
      days = var.etcd_snapshot_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 3
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  depends_on = [aws_s3_bucket_versioning.etcd_backups]
}

data "aws_iam_policy_document" "etcd_backups" {
  # Deny anything that is not TLS. An unencrypted PUT to an SSE-KMS bucket fails
  # anyway, but a Deny on s3:x-amz-server-side-encryption catches a client that
  # would otherwise silently retry and log confusing errors.
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.etcd_backups.arn,
      "${aws_s3_bucket.etcd_backups.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "DenyUnencryptedObjectUploads"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:PutObject"]

    resources = ["${aws_s3_bucket.etcd_backups.arn}/*"]

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }
}

resource "aws_s3_bucket_policy" "etcd_backups" {
  bucket = aws_s3_bucket.etcd_backups.id
  policy = data.aws_iam_policy_document.etcd_backups.json
}
