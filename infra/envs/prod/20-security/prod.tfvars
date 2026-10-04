# Phase 3 (20-security) settings for prod.
#
# Applied with:
#   terraform plan -input=false "-var-file=..\common.tfvars" "-var-file=prod.tfvars"

# Traefik's HTTP NodePort. HTTPS terminates at the ALB, so only one NodePort is
# needed. The module rejects 22 here, which is what keeps SSH out of the
# security groups entirely.
traefik_nodeports = [30080]

# Bucket names the node role is granted object access to in the IAM policy.
# The check block in main.tf asserts these match the names 60-ops derives,
# so the two layers cannot drift.
etcd_backup_bucket_name     = "dpx-prod-etcd-backups"
postgres_backup_bucket_name = "dpx-prod-postgres-backups"

# KMS deletion window. 30 days is the AWS maximum, and matches the bootstrap
# state-key policy so an accidental key deletion can be caught in time.
kms_deletion_window_in_days = 30

# ssm_path_prefix is left null so it derives to /dpx/prod/k8s. Set it only if
# this account hosts another project that needs its own namespace.
