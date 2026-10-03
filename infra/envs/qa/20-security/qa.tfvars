# Phase 3 (20-security) settings for qa.
#
# Applied with:
#   terraform plan -input=false "-var-file=..\common.tfvars" "-var-file=qa.tfvars"

# Traefik's HTTP NodePort. HTTPS terminates at the ALB, so only one NodePort is
# needed. The module rejects 22 here, which is what keeps SSH out of the
# security groups entirely.
traefik_nodeports = [30080]

# Bucket names the node role is granted object access to in the IAM policy.
# The check block in main.tf asserts these match the names 70-backups derives,
# so the two layers cannot drift.
etcd_backup_bucket_name     = "dpx-qa-etcd-backups"
postgres_backup_bucket_name = "dpx-qa-postgres-backups"

# KMS deletion window. QA keys are still held for 30 days so an accidental
# deletion during testing can be caught.
kms_deletion_window_in_days = 30

# ssm_path_prefix is left null so it derives to /dpx/qa/k8s. Prod and QA paths
# never overlap, so the node role in one environment cannot read the other's
# join tokens or kubeconfigs.
