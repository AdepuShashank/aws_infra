output "alerts_topic_arn" {
  description = "Ops SNS topic every alarm in this layer publishes to."
  value       = aws_sns_topic.ops_alerts.arn
}

output "alerts_topic_name" {
  description = "Ops SNS topic name."
  value       = aws_sns_topic.ops_alerts.name
}

output "alert_email_subscription_arn" {
  description = "ARN of the email subscription. Subscribes as PENDING_CONFIRMATION; AWS emails the confirmation and nothing is delivered until it is clicked."
  value       = aws_sns_topic_subscription.alert_email.arn
}

output "alert_email_pending_confirmation" {
  description = "TRUE until the recipient confirms the subscription. Alarms are firing correctly the whole time this is true; they just are not arriving."
  value       = aws_sns_topic_subscription.alert_email.pending_confirmation
}

output "log_group_names" {
  description = "Log groups the CloudWatch agent ships to. Empty when enable_agent = false."
  value = {
    for key, group in aws_cloudwatch_log_group.agent : key => group.name
  }
}

output "log_group_arns" {
  description = "ARNs of the log groups, for anything that needs to write to them directly."
  value = {
    for key, group in aws_cloudwatch_log_group.agent : key => group.arn
  }
}

output "alarm_names" {
  description = "Every alarm this layer created, and which condition it watches. An alarm missing from this map is one whose dependency had not been applied when this ran - see cluster_dependencies below."
  value = merge(
    length(aws_cloudwatch_metric_alarm.alb_unhealthy_targets) > 0 ? { alb_unhealthy_targets = aws_cloudwatch_metric_alarm.alb_unhealthy_targets[0].alarm_name } : {},
    length(aws_cloudwatch_metric_alarm.alb_5xx) > 0 ? { alb_5xx = aws_cloudwatch_metric_alarm.alb_5xx[0].alarm_name } : {},
    length(aws_cloudwatch_metric_alarm.asg_capacity_shortfall) > 0 ? { asg_capacity_shortfall = aws_cloudwatch_metric_alarm.asg_capacity_shortfall[0].alarm_name } : {},
    length(aws_cloudwatch_metric_alarm.asg_min_size) > 0 ? { asg_min_size_reference = aws_cloudwatch_metric_alarm.asg_min_size[0].alarm_name } : {},
    length(aws_cloudwatch_metric_alarm.control_plane_status_check) > 0 ? { control_plane_status_check = aws_cloudwatch_metric_alarm.control_plane_status_check[0].alarm_name } : {},
    length(aws_cloudwatch_metric_alarm.etcd_snapshot_stale) > 0 ? { etcd_snapshot_stale = aws_cloudwatch_metric_alarm.etcd_snapshot_stale[0].alarm_name } : {},
  )
}

output "alarm_count" {
  description = "How many alarms exist. Not five-and-four: the ALB pair needs 40-edge and the rest need 30-cluster, so this is a useful read on how much of the environment is actually applied."
  value = (
    length(aws_cloudwatch_metric_alarm.alb_unhealthy_targets) +
    length(aws_cloudwatch_metric_alarm.alb_5xx) +
    length(aws_cloudwatch_metric_alarm.asg_capacity_shortfall) +
    length(aws_cloudwatch_metric_alarm.asg_min_size) +
    length(aws_cloudwatch_metric_alarm.control_plane_status_check) +
    length(aws_cloudwatch_metric_alarm.etcd_snapshot_stale)
  )
}

output "cluster_dependencies" {
  description = "Which earlier layers this layer could find. Read this before trusting the alarm list: an environment with has_cluster = false has no alarms at all, by design rather than by failure."
  value = {
    has_cluster = local.has_cluster
    has_edge    = local.has_edge
  }
}

output "cloudwatch_agent_document_name" {
  description = "SSM document that installs the CloudWatch agent, or null when the agent is disabled or 30-cluster has not been applied. Pass it to `aws ssm send-command` to run it by hand."
  value       = one(aws_ssm_document.cloudwatch_agent[*].name)
}

output "backup_probe_document_name" {
  description = "SSM document that publishes the etcd snapshot age metric, or null when disabled or 30-cluster has not been applied."
  value       = one(aws_ssm_document.backup_probe[*].name)
}

output "backup_probe_association_id" {
  description = "Association running the backup probe hourly."
  value       = one(aws_ssm_association.backup_probe[*].id)
}

output "metric_namespace" {
  description = "CloudWatch custom namespace the backup probe publishes to."
  value       = local.metric_namespace
}

output "how_to_check_alarms" {
  description = "The two commands that answer 'is anything wrong', for a reader who does not have the console open."
  value = {
    alarms  = "aws cloudwatch describe-alarms --alarm-name-prefix <${var.project}-${var.env}-> --state-value ALARM --region ${var.aws_region}"
    history = "aws cloudwatch get-metric-statistics --namespace ${local.metric_namespace} --metric-name EtcdSnapshotAgeMinutes --dimensions Name=Env,Value=${var.env} Name=Component,Value=etcd --start-time <iso8601> --end-time <iso8601> --period 3600 --statistics Maximum --region ${var.aws_region}"
  }
}
