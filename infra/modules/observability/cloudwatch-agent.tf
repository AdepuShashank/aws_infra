# ---------------------------------------------------------------------------
# CloudWatch agent, installed by SSM
# ---------------------------------------------------------------------------
# Phase 3 attached CloudWatchAgentServerPolicy to the node role "for the CloudWatch
# agent" and nothing has ever installed one. This closes that gap, and it closes
# it the same way Phase 6 configures the cluster: over SSM, on the instance, from a
# document that lives in Terraform so the configuration is a reviewable diff.
#
# Deliberately not in cloud-init: the control plane's user_data is already at EC2's
# 16,384-byte ceiling (see modules/cluster/user-data-guard.tf), and the workers'
# user-data is shared with kubeadm join. An association is also re-runnable, which
# means a node that was replaced converges without anyone noticing.

locals {
  # Only these two values vary per environment; the collected files are fixed.
  # {instance_id} is the CloudWatch agent's own placeholder for the instance
  # dimension, not a shell or Terraform expansion - which is why it is written
  # without a dollar sign and survives templatefile unchanged.
  agent_config = jsonencode({
    agent = {
      region = var.aws_region
      debug  = false
    }
    logs = {
      log_format = "text"
      journald = {
        log_group_name  = "${local.log_group_prefix}/journal"
        log_stream_name = "{instance_id}/journal"
      }
      files_collected = {
        "/var/log/amazon/ssm/amazon-ssm-agent.log" = {
          log_group_name  = "${local.log_group_prefix}/ssm-agent"
          log_stream_name = "{instance_id}/ssm-agent"
        }
      }
    }
  })

  agent_script = templatefile("${path.module}/templates/install-cloudwatch-agent.sh.tftpl", {
    region       = var.aws_region
    agent_config = local.agent_config
  })
}

resource "aws_ssm_document" "cloudwatch_agent" {
  count = var.enable_agent && local.has_cluster ? 1 : 0

  name          = module.naming["agent_document"].full_name
  document_type = "Command"

  # mainSteps rather than mainType/content: this endpoint rejects the documented
  # modern shape with "Unknown property". Same reason, same fix as
  # modules/platform-bootstrap. See docs/adr/0003-ssm-document-and-join-token.md.
  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Install and configure the CloudWatch agent on ${var.project}/${var.env} nodes. Managed by Terraform."
    parameters    = {}
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "installCloudWatchAgent"
        inputs = {
          # One entry, not one per line: each entry gets its own shell and its own
          # exit code, so `set -e` would only apply within a line.
          runCommand = [local.agent_script]
        }
      }
    ]
  })

  tags = local.resource_tags["agent_document"]
}

resource "aws_ssm_association" "cloudwatch_agent" {
  count = var.enable_agent && local.has_cluster ? 1 : 0

  # association_name is the association's name; name is the DOCUMENT it runs.
  association_name = module.naming["agent_association"].full_name
  name             = aws_ssm_document.cloudwatch_agent[0].name
  document_version = aws_ssm_document.cloudwatch_agent[0].latest_version

  targets {
    key    = "InstanceIds"
    values = [var.control_plane_instance_id]
  }

  schedule_expression              = "rate(6 hours)"
  apply_only_at_cron_interval      = false
  wait_for_success_timeout_seconds = 600

  # Output is not sent to S3. Everything this script prints is either an error
  # that shows up as a Failed status on the association, or is written to the
  # agent's own log group - which is one of the two groups this association exists
  # to populate.
  tags = local.resource_tags["agent_association"]
}
