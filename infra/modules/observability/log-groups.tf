# ---------------------------------------------------------------------------
# Log groups
# ---------------------------------------------------------------------------
# Destinations, created here so they exist before the agent starts. The agent is
# installed and configured by the SSM association in cloudwatch-agent.tf, and it
# creates nothing: with a `logs.files_collected` entry pointing at a group that
# does not exist, the agent starts, reports a configuration error once per
# collection cycle, and ships nothing.
#
# Retention is explicit on every group. CloudWatch Logs never expires a group on
# its own, and the default is "keep forever" - on a cluster that reboots, that is
# the difference between a bounded bill and an unbounded one.

locals {
  # journald rather than /var/log/syslog or /var/log/kern.log. Those files only
  # exist if rsyslog is installed, and the CloudWatch agent does not skip a missing
  # file quietly - it logs an error for it every cycle. journald is always present
  # on Ubuntu 24.04 and holds everything those files would have held.
  log_groups = {
    journal = {
      suffix = "journal"
      days   = var.agent_log_retention_days
    }
    ssm_agent = {
      suffix = "ssm-agent"
      days   = var.agent_log_retention_days
    }
  }
}

resource "aws_cloudwatch_log_group" "agent" {
  for_each = var.enable_agent ? local.log_groups : {}

  name              = "${local.log_group_prefix}/${each.value.suffix}"
  retention_in_days = each.value.days

  tags = merge(local.resource_tags["agent_log_group"], {
    Name = "${local.log_group_prefix}/${each.value.suffix}"
  })
}
