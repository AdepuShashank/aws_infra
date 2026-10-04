# ---------------------------------------------------------------------------
# Backup freshness probe
# ---------------------------------------------------------------------------
# "Is the etcd backup timer still working?" has no CloudWatch metric behind it: the
# snapshot timer runs as a systemd oneshot on the control plane, so nothing
# publishes a number that an alarm can watch. That is the whole failure mode this
# closes - a timer that silently stopped is indistinguishable from a healthy
# cluster until the day something needs restoring.
#
# The probe asks the bucket directly, once an hour, and publishes the age of the
# newest snapshot as a custom metric. The alarm in alarms.tf treats missing data as
# breaching, so a probe that stops running also fires.
#
# An association rather than a Schedule, deliberately: an association only runs on
# an instance that is online. When the environment is paused for cost the probe
# stops, publishes nothing, and no alarm fires - which is correct, because a
# stopped cluster having no new snapshots is not a backup failure. An EventBridge
# schedule would run anyway, fail to reach a stopped instance, and page someone
# every night.

locals {
  probe_script = templatefile("${path.module}/templates/backup-freshness-probe.sh.tftpl", {
    region           = var.aws_region
    env              = var.env
    etcd_bucket      = var.etcd_backup_bucket_name
    metric_namespace = local.metric_namespace
  })
}

resource "aws_ssm_document" "backup_probe" {
  count = var.enable_backup_probe && local.has_cluster ? 1 : 0

  name          = module.naming["probe_document"].full_name
  document_type = "Command"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Publish the age of the newest ${var.project}/${var.env} etcd snapshot as the ${local.metric_namespace} EtcdSnapshotAgeMinutes metric. Managed by Terraform."
    parameters    = {}
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "backupFreshnessProbe"
        inputs = {
          runCommand = [local.probe_script]
        }
      }
    ]
  })

  tags = local.resource_tags["probe_document"]
}

resource "aws_ssm_association" "backup_probe" {
  count = var.enable_backup_probe && local.has_cluster ? 1 : 0

  association_name = module.naming["probe_association"].full_name
  name             = aws_ssm_document.backup_probe[0].name
  document_version = aws_ssm_document.backup_probe[0].latest_version

  targets {
    key    = "InstanceIds"
    values = [var.control_plane_instance_id]
  }

  schedule_expression              = var.probe_schedule
  apply_only_at_cron_interval      = false
  wait_for_success_timeout_seconds = var.probe_timeout_seconds

  tags = local.resource_tags["probe_association"]
}
