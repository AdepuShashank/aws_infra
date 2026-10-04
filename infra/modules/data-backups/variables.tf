variable "project" {
  description = "Project identifier used in resource names and tags. Lowercase, no spaces."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.project))
    error_message = "project must be lowercase alphanumeric/hyphen, 2-21 chars, starting with a letter."
  }
}

variable "env" {
  description = "Deployment environment (prod or qa)."
  type        = string

  validation {
    condition     = contains(["prod", "qa"], var.env)
    error_message = "env must be one of: prod, qa."
  }
}

variable "layer" {
  description = "Terraform layer this root module represents. Used for naming and tagging only."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{2}-[a-z-]+$", var.layer))
    error_message = "layer must look like NN-name, e.g. 60-ops."
  }
}

variable "owner" {
  description = "Accountable owner tag value."
  type        = string
}

variable "cost_center" {
  description = "Cost allocation tag value."
  type        = string
}

variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "ap-south-1"
}

variable "extra_tags" {
  description = "Additional tags merged on top of the standard tag set."
  type        = map(string)
  default     = {}
}

# --------------------------------------------------------------------------- #
# Bucket names
# --------------------------------------------------------------------------- #
# Both names are owned by 20-security, which is where the node role's S3 grants
# are written. This module creates the postgres bucket and asserts that the names
# it is given match what IAM already assumes, because a mismatch fails at backup
# time (AccessDenied) rather than at apply time.

variable "postgres_backup_bucket_name" {
  description = "Name of the PostgreSQL backup bucket. Must match the name 20-security grants the node role."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.postgres_backup_bucket_name))
    error_message = "postgres_backup_bucket_name must be a valid S3 bucket name."
  }
}

variable "etcd_backup_bucket_name" {
  description = <<-EOT
    Name of the etcd backup bucket. NOT created here - 30-cluster creates it,
    because Phase 4 is the first layer that needs it and the control plane's
    snapshot timer uploads on first boot. This module only needs the name, to
    scope the DLM policy's tag filter and to report both buckets together.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.etcd_backup_bucket_name))
    error_message = "etcd_backup_bucket_name must be a valid S3 bucket name."
  }
}

# ---------------------------------------------------------------- encryption --

variable "backup_kms_key_arn" {
  description = "KMS key used for SSE-KMS on both backup buckets. Must be the EBS key from 20-security: the node role's EBSKeyUsage statement is what lets `aws s3 cp --sse aws:kms` succeed, and a different key would fail every upload."
  type        = string
}

variable "bucket_key_enabled" {
  description = "S3 Bucket Keys. Cuts KMS request cost for objects under ~64 KiB, which is what a small etcd snapshot on an empty cluster is. The snapshots grow past that quickly, so this is a small win that costs nothing."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------- retention --

variable "postgres_backup_retention_days" {
  description = "Days a logical PostgreSQL dump is kept in the backup bucket before S3 expires it."
  type        = number
  default     = 14

  validation {
    condition     = var.postgres_backup_retention_days >= 7 && var.postgres_backup_retention_days <= 365
    error_message = "postgres_backup_retention_days must be between 7 and 365."
  }
}

# --------------------------------------------------------- DLM / EBS snapshots --

variable "dlm_enabled" {
  description = "Create the Data Lifecycle Manager policy for EBS snapshots."
  type        = bool
  default     = true
}

variable "dlm_interval_hours" {
  description = "How often the DLM policy runs. DLM deletes a snapshot when it passes both this age and the policy's own retention, so this is an upper bound on how long a deletion can be missed, not a retention setting."
  type        = number
  default     = 24

  validation {
    condition     = var.dlm_interval_hours >= 1 && var.dlm_interval_hours <= 48
    error_message = "dlm_interval_hours must be between 1 and 48; DLM accepts no wider interval."
  }
}

variable "dlm_retention_days" {
  description = <<-EOT
    How long the DLM policy keeps an EBS snapshot before deleting it. Applies to
    snapshots tagged for this environment: CloudNativePG volume snapshots, and
    any manual ec2 create-snapshot a human took while debugging a node.
  EOT
  type        = number
  default     = 14

  validation {
    condition     = var.dlm_retention_days >= 7 && var.dlm_retention_days <= 365
    error_message = "dlm_retention_days must be between 7 and 365."
  }
}
