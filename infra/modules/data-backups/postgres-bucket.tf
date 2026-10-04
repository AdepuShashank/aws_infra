# ---------------------------------------------------------------------------
# PostgreSQL backup bucket
# ---------------------------------------------------------------------------
# Same shape as the etcd bucket in modules/cluster: versioning, SSE-KMS with a
# customer-managed key, ACLs disabled entirely, and a policy that denies anything
# that is not TLS or not KMS-encrypted. The reasons are the same ones - a logical
# dump is a full copy of every project's data, so it gets the same treatment.
#
# Note on what writes here, because it is not the obvious answer:
#
# CloudNativePG's own S3 backup (`spec.backup.barmanObjectStore`) is NOT
# configured, even though this bucket exists and the node role is allowed to
# write it. The in-tree barman plugin authenticates with a Kubernetes Secret
# holding an `access-key-id` and a `secret-access-key`. Those are long-lived AWS
# access keys, and this project's fixed decisions rule those out: there are none
# in the account, and the whole Phase 3 baseline exists so that a compromised pod
# cannot reach one. Trading that for WAL archiving on a single-instance
# throwaway database would be a bad trade.
#
# What replaces it: `spec.backup.volumeSnapshot` on the CNPG Cluster, which is
# in-cluster (no credentials, no egress) and produces EBS snapshots that this
# layer's DLM policy reclaims. The trade is that a volume snapshot is only
# recoverable onto the same volume type and size, and its RPO is the backup
# schedule rather than continuous. For ten projects on a shared development
# database that is the right side of the trade; for a production database it
# would not be, and the fix would be IRSA on the cluster plus the barman plugin's
# IAM auth, not static keys.

resource "aws_s3_bucket" "postgres_backups" {
  bucket = var.postgres_backup_bucket_name

  tags = merge(local.resource_tags["postgres_backup_bucket"], {
    Name = var.postgres_backup_bucket_name
  })
}

resource "aws_s3_bucket_public_access_block" "postgres_backups" {
  bucket                  = aws_s3_bucket.postgres_backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "postgres_backups" {
  bucket = aws_s3_bucket.postgres_backups.id

  # The same KMS key the node role's EBSKeyUsage statement already allows. A
  # separate key would need a second kms:GenerateDataKey grant on the node role,
  # and the upload would fail with AccessDenied while the CNPG backup object
  # reported itself healthy - the failure mode the etcd timer's own error handling
  # was written to avoid.
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.backup_kms_key_arn
    }

    bucket_key_enabled = var.bucket_key_enabled
  }
}

resource "aws_s3_bucket_versioning" "postgres_backups" {
  bucket = aws_s3_bucket.postgres_backups.id

  # On, despite the lifecycle rule below. A restore that turns out to be from the
  # wrong day is recoverable inside the grace window; without versioning it is not.
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_ownership_controls" "postgres_backups" {
  bucket = aws_s3_bucket.postgres_backups.id

  rule {
    # BucketOwnerEnforced: ACLs do not exist. Nothing that writes here can widen
    # its own access by attaching a canned ACL, which is the only thing
    # bucket-owner-full-control would buy.
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "postgres_backups" {
  bucket = aws_s3_bucket.postgres_backups.id

  rule {
    id     = "postgres-dump-expiry"
    status = "Enabled"

    filter {
      prefix = ""
    }

    expiration {
      days = var.postgres_backup_retention_days
    }

    # Noncurrent versions go first and much sooner. A dump is only superseded when
    # a newer one of the same name lands, and the current versions are the ones a
    # restore actually uses, so expiring the superseded copies aggressively costs
    # nothing and keeps the bucket from being dominated by them.
    noncurrent_version_expiration {
      noncurrent_days = 3
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  depends_on = [aws_s3_bucket_versioning.postgres_backups]
}

data "aws_iam_policy_document" "postgres_backups" {
  # Deny anything that is not TLS. The uploads go over the S3 gateway endpoint
  # inside the VPC, so this never fires in normal operation - which is the point
  # of a Deny that never fires.
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.postgres_backups.arn,
      "${aws_s3_bucket.postgres_backups.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # Deny uploads that are not KMS-encrypted. Without this an unencrypted write
  # fails anyway - SSE-KMS is the bucket default - but it fails on the response
  # rather than on the request, and a client that retries on AccessDenied can
  # leave a partially written object behind.
  statement {
    sid    = "DenyUnencryptedObjectUploads"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.postgres_backups.arn}/*"]

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }
}

resource "aws_s3_bucket_policy" "postgres_backups" {
  bucket = aws_s3_bucket.postgres_backups.id
  policy = data.aws_iam_policy_document.postgres_backups.json
}
