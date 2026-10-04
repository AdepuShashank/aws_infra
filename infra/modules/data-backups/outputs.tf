output "postgres_backup_bucket_name" {
  description = "Name of the PostgreSQL backup bucket created here."
  value       = aws_s3_bucket.postgres_backups.id
}

output "postgres_backup_bucket_arn" {
  description = "ARN of the PostgreSQL backup bucket."
  value       = aws_s3_bucket.postgres_backups.arn
}

output "etcd_backup_bucket_name" {
  description = "Name of the etcd backup bucket. Created by 30-cluster, not here - see the module header."
  value       = var.etcd_backup_bucket_name
}

output "backup_buckets" {
  description = "Both backup buckets for this environment, with which layer owns each. Anything restoring from these needs this map."
  value = {
    etcd = {
      name        = var.etcd_backup_bucket_name
      owner_layer = "30-cluster"
      contents    = "etcdctl snapshot save, every 6h, uploaded by the control plane's systemd timer"
      retention   = "S3 lifecycle, 14 days"
    }
    postgres = {
      name        = aws_s3_bucket.postgres_backups.id
      owner_layer = var.layer
      contents    = "logical pg_dump, plus CloudNativePG volume snapshots (EBS, reclaimed by the DLM policy below)"
      retention   = "S3 lifecycle ${var.postgres_backup_retention_days} days; DLM ${var.dlm_retention_days} days for EBS snapshots"
    }
  }
}

output "dlm_policy_id" {
  description = "DLM lifecycle policy id, or null when dlm_enabled = false."
  value       = one(aws_dlm_lifecycle_policy.ebs[*].id)
}

output "dlm_policy_arn" {
  description = "DLM lifecycle policy ARN, or null when dlm_enabled = false."
  value       = one(aws_dlm_lifecycle_policy.ebs[*].arn)
}

output "dlm_role_arn" {
  description = "Role DLM assumes to delete snapshots, or null when dlm_enabled = false."
  value       = one(aws_iam_role.dlm[*].arn)
}

output "encryption_summary" {
  description = "Encryption posture of both buckets, for review against the Phase 3 baseline."
  value = {
    algorithm   = "aws:kms"
    kms_key_arn = var.backup_kms_key_arn
    bucket_keys = var.bucket_key_enabled
    acls        = "BucketOwnerEnforced (ACLs disabled)"
    versioning  = "Enabled on both buckets"
    tls_only    = true
  }
}

output "restore_documentation" {
  description = "Where the restore procedures live. Neither is automated: a restore replaces cluster state, so it is a documented human decision."
  value = {
    etcd     = "docs/etcd-restore.md"
    postgres = "docs/backups.md (pg_dump: psql -f; volume snapshot: restore into a new CNPG Cluster with the same storage class)"
    helper   = "scripts/etcd-restore.sh"
  }
}
