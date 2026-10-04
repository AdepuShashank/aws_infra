# ---------------------------------------------------------------------------
# Alarms
# ---------------------------------------------------------------------------
# Five checks. Each one answers "is the thing still working?", not "is the metric
# interesting?", and each one is cheap enough to leave on: an alarm with no
# dimension data costs CloudWatch nothing and does nothing, an alarm that fires
# costs cents, and there is no per-alarm fee.
#
# Every alarm shares one shape deliberately:
#
#   treat_missing_data = "breaching"   for anything that should always be running
#   treat_missing_data = "notBreaching" for anything that is expected to go quiet
#
# Getting that backwards is the classic CloudWatch mistake: a check whose whole
# purpose is "tell me when this stops reporting" is defeated by an alarm that
# treats silence as health. So the etcd freshness alarm, the ASG shortfall alarm
# and the ALB health alarm all treat missing data as breaching. The 5xx alarm does
# not, because an ALB with no traffic at all is a healthy ALB at 3am.

locals {
  alarm_actions = [aws_sns_topic.ops_alerts.arn]
}

# --- ALB: targets are registered but nothing is serving ------------------------
# The single most useful alarm in this list for this architecture, because the
# target group is wired up in 40-edge while Traefik arrives in Phase 7. Until that
# app syncs, this alarm is permanently breaching - which is correct information,
# not a false positive.
resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_targets" {
  count = local.enabled && local.has_edge ? 1 : 0

  alarm_name        = "${module.naming["alerts_topic"].full_name}-alb-unhealthy-targets"
  alarm_description = "The ALB has targets registered but at least one is failing its health check. In this architecture that usually means Traefik is not running or is not listening on the expected NodePort."

  namespace   = "AWS/ApplicationELB"
  metric_name = "UnHealthyHostCount"
  statistic   = "Maximum"

  dimensions = {
    LoadBalancer = local.alb_dimension
  }

  period             = 60
  evaluation_periods = 2
  threshold          = 0

  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching"

  alarm_actions = local.alarm_actions

  tags = local.resource_tags["alerts_topic"]
}

# --- ALB: requests are reaching a backend and failing --------------------------
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  count = local.enabled && local.has_edge ? 1 : 0

  alarm_name        = "${module.naming["alerts_topic"].full_name}-alb-target-5xx"
  alarm_description = "Requests forwarded by the ALB are being answered with a 5xx by the target."

  namespace   = "AWS/ApplicationELB"
  metric_name = "HTTPCode_Target_5XX_Count"
  statistic   = "Sum"

  dimensions = {
    LoadBalancer = local.alb_dimension
  }

  period             = 300
  evaluation_periods = 1
  threshold          = var.alb_5xx_threshold

  comparison_operator = "GreaterThanThreshold"

  # Not breaching. An ALB serving nothing publishes no datapoints at all, and
  # treating that as a failure would page every night on a paused environment.
  treat_missing_data = "notBreaching"

  alarm_actions = local.alarm_actions

  tags = local.resource_tags["alerts_topic"]
}

# --- Worker ASG: fewer healthy nodes than the group asked for ------------------
# Expressed as a comparison rather than a threshold, because "GroupInServiceInstances"
# has no fixed right value: it tracks GroupMinSize, which is 1 in prod at this
# account's quota and 0 in qa. A hardcoded threshold of 0 would never fire and a
# hardcoded 1 would fire forever in qa.
resource "aws_cloudwatch_metric_alarm" "asg_capacity_shortfall" {
  count = local.enabled && var.worker_asg_name != null ? 1 : 0

  alarm_name        = "${module.naming["alerts_topic"].full_name}-worker-capacity-shortfall"
  alarm_description = "The worker ASG has fewer in-service instances than its configured minimum. On this account that usually means VcpuLimitExceeded - see docs/quota.md."

  namespace   = "AWS/AutoScaling"
  metric_name = "GroupInServiceInstances"
  statistic   = "Minimum"

  dimensions = {
    AutoScalingGroupName = var.worker_asg_name
  }

  period             = 120
  evaluation_periods = 3

  comparison_operator = "LessThanThreshold"

  # The right-hand side is a second metric rather than a constant, so the alarm
  # follows GroupMinSize instead of a number typed into this file.
  threshold_metric_id = "asg_min_size"

  # breaching, because a group that has stopped reporting at all is in a worse
  # state than one reporting a shortfall.
  treat_missing_data = "breaching"

  alarm_actions = local.alarm_actions

  tags = local.resource_tags["alerts_topic"]
}

resource "aws_cloudwatch_metric_alarm" "asg_min_size" {
  count = local.enabled && var.worker_asg_name != null ? 1 : 0

  alarm_name        = "${module.naming["alerts_topic"].full_name}-worker-min-size-reference"
  alarm_description = "Reference value for the capacity-shortfall comparison. Not a real alarm; it exists only to put GroupMinSize into the comparison expression."

  namespace   = "AWS/AutoScaling"
  metric_name = "GroupMinSize"
  statistic   = "Minimum"

  dimensions = {
    AutoScalingGroupName = var.worker_asg_name
  }

  period             = 120
  evaluation_periods = 1

  # Carrying the number as the "threshold" is the documented idiom for feeding one
  # alarm's metric into another's threshold; the action list is empty so this never
  # notifies anyone on its own.
  threshold = 0

  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  tags = local.resource_tags["alerts_topic"]
}

# --- Control plane: EC2's own status checks ------------------------------------
# The API server is the whole cluster. A failed status check means an instance
# reachable through IMDS but not actually healthy, which is a state `kubectl` will
# report as a connection timeout rather than as the real cause.
resource "aws_cloudwatch_metric_alarm" "control_plane_status_check" {
  count = local.enabled ? 1 : 0

  alarm_name        = "${module.naming["alerts_topic"].full_name}-control-plane-status-check-failed"
  alarm_description = "EC2 reports a failed status check on the control plane. The kubeadm API server lives on this instance, so every node's kubeconfig is currently pointing at something unhealthy."

  namespace   = "AWS/EC2"
  metric_name = "StatusCheckFailed_System"
  statistic   = "Maximum"

  dimensions = {
    InstanceId = var.control_plane_instance_id
  }

  period             = 60
  evaluation_periods = 2
  threshold          = 0

  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching"

  alarm_actions = local.alarm_actions

  tags = local.resource_tags["alerts_topic"]
}

# --- Backups: the newest etcd snapshot is too old ------------------------------
# Feeds off the custom metric published by the SSM association in
# backup-freshness.tf. Not a mistake: the snapshot timer is a systemd oneshot and
# publishes nothing of its own.
resource "aws_cloudwatch_metric_alarm" "etcd_snapshot_stale" {
  count = local.enabled && var.enable_backup_probe ? 1 : 0

  alarm_name        = "${module.naming["alerts_topic"].full_name}-etcd-snapshot-stale"
  alarm_description = "The newest etcd snapshot in S3 is older than the snapshot interval. A restore would roll the cluster back further than intended."

  namespace   = local.metric_namespace
  metric_name = "EtcdSnapshotAgeMinutes"
  statistic   = "Maximum"

  dimensions = {
    Env       = var.env
    Component = "etcd"
  }

  period             = 3600
  evaluation_periods = 2
  threshold          = var.etcd_snapshot_stale_minutes

  comparison_operator = "GreaterThanThreshold"

  # The important setting on this alarm. The probe publishes nothing when it
  # cannot list the bucket, and silence here means "backups are unverified" - which
  # is the condition this alarm exists to surface.
  treat_missing_data = "breaching"

  alarm_actions = local.alarm_actions

  tags = local.resource_tags["alerts_topic"]
}
