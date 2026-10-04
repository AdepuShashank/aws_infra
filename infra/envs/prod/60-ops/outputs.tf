output "layer" {
  description = "Layer name."
  value       = module.foundation.layer
}

output "env" {
  description = "Environment name."
  value       = module.foundation.env
}

output "name_prefix" {
  description = "Resource name prefix (project-env)."
  value       = module.foundation.name_prefix
}

output "standard_tags" {
  description = "Standard tag map applied to every resource in this layer."
  value       = module.foundation.standard_tags
}

output "aws_account_id" {
  description = "AWS account id resolved via STS."
  value       = module.foundation.aws_account_id
}

# ---------------------------------------------------------------------------
# Backups
# ---------------------------------------------------------------------------
output "postgres_backup_bucket" {
  description = "Name of the PostgreSQL backup bucket created here."
  value       = module.data_backups.postgres_backup_bucket_name
}

output "backup_buckets" {
  description = "Both backup buckets, with which layer owns each and what lands in them."
  value       = module.data_backups.backup_buckets
}

output "dlm_policy_id" {
  description = "DLM lifecycle policy that reclaims EBS snapshots, or null when disabled."
  value       = module.data_backups.dlm_policy_id
}

output "encryption_summary" {
  description = "Encryption posture of both backup buckets."
  value       = module.data_backups.encryption_summary
}

output "restore_documentation" {
  description = "Where the restore procedures live."
  value       = module.data_backups.restore_documentation
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------
output "alerts_topic_arn" {
  description = "SNS topic every alarm in this layer publishes to."
  value       = module.observability.alerts_topic_arn
}

output "alerts_topic_name" {
  description = "Ops SNS topic name."
  value       = module.observability.alerts_topic_name
}

output "alert_email_pending_confirmation" {
  description = "TRUE until alert_email is confirmed. Alarms are evaluating correctly the whole time; they just are not arriving."
  value       = module.observability.alert_email_pending_confirmation
}

output "alarm_names" {
  description = "Every alarm created, and which condition each watches. An alarm missing from this map is one whose layer had not been applied."
  value       = module.observability.alarm_names
}

output "alarm_count" {
  description = "How many alarms exist. Not six: the ALB pair needs 40-edge and the rest need 30-cluster, so this reads as a rough measure of how much of the environment is applied."
  value       = module.observability.alarm_count
}

output "cluster_dependencies" {
  description = "Which earlier layers this layer found. Check this before trusting the alarm list."
  value       = module.observability.cluster_dependencies
}

output "log_groups" {
  description = "Log groups the CloudWatch agent ships to."
  value       = module.observability.log_group_names
}

output "cloudwatch_agent_document_name" {
  description = "SSM document that installs the CloudWatch agent, or null when disabled."
  value       = module.observability.cloudwatch_agent_document_name
}

output "backup_probe_document_name" {
  description = "SSM document that publishes the etcd snapshot age metric, or null when disabled."
  value       = module.observability.backup_probe_document_name
}

output "how_to_check_alarms" {
  description = "The two commands that answer 'is anything wrong', for a reader without the console."
  value       = module.observability.how_to_check_alarms
}

# ---------------------------------------------------------------------------
# Scheduler
# ---------------------------------------------------------------------------
output "scheduler" {
  description = "Whether scheduled stop/start is on, what it targets, and the cron expressions in force."
  value       = module.scheduler.status
}

output "schedule_expressions" {
  description = "The stop and start cron expressions and their timezone."
  value       = module.scheduler.schedule_expressions
}

output "scheduler_cost_note" {
  description = "What the schedules cost. EventBridge Scheduler bills per invocation, not per schedule."
  value       = module.scheduler.cost_note
}

# ---------------------------------------------------------------------------
# For later layers and for scripts/up.sh
# ---------------------------------------------------------------------------
output "control_plane_instance_id" {
  description = "Control plane instance id, resolved from 30-cluster. Null when that layer has not been applied."
  value       = local.control_plane_instance_id
}

output "nat_instance_id" {
  description = "NAT instance id, resolved from 10-network. scripts/down.sh targets this."
  value       = local.nat_instance_id
}

output "layer_summary" {
  description = "One map of everything this layer manages, for a human who wants the shape of an environment without reading three modules."
  value = {
    backups = {
      etcd_bucket     = local.etcd_backup_bucket_name
      postgres_bucket = local.postgres_backup_bucket_name
      dlm_enabled     = var.dlm_enabled
    }
    observability = {
      topic         = module.observability.alerts_topic_name
      alarms        = module.observability.alarm_count
      log_groups    = length(module.observability.log_group_names)
      agent_enabled = var.enable_cloudwatch_agent
      probe_enabled = var.enable_backup_probe
    }
    scheduler = module.scheduler.status
  }
}
