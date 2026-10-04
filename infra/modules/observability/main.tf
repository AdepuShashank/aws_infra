# ---------------------------------------------------------------------------
# Observability (60-ops)
# ---------------------------------------------------------------------------
# Three things, and the reason each one exists here rather than somewhere else:
#
#   SNS topic        Alarms have to go somewhere. infra/bootstrap already owns a
#                    topic for budget breaches; this one is separate because that
#                    topic's policy lives in a bootstrap state and this layer must
#                    be re-appliable without touching bootstrap. Budget noise and
#                    "the cluster is broken" noise should also be separable by
#                    subscription.
#
#   Log groups       Destinations for the CloudWatch agent, which Phase 3 already
#                    granted the node role permissions to run but nothing has ever
#                    installed or configured. That gap is why these groups would
#                    otherwise sit empty forever.
#
#   Alarms           Four "the thing you care about has stopped working" checks,
#                    plus one for backup freshness. Chosen so that each one, if it
#                    fires while nobody is watching, describes an outage nobody
#                    would otherwise have noticed.
#
# There is deliberately no Prometheus or Grafana. kube-prometheus-stack on a
# single-worker cluster does not fit next to Traefik, CNPG and the CSI driver, and
# an ALB 5xx alarm does not need a query language to be useful.

locals {
  name_prefix = "${var.project}-${var.env}"

  naming_resources = {
    alerts_topic      = "ops-alerts"
    agent_log_group   = "node-agent-logs"
    agent_document    = "cloudwatch-agent-doc"
    agent_association = "cloudwatch-agent-assoc"
    probe_document    = "backup-probe-doc"
    probe_association = "backup-probe-assoc"
  }

  # Metric namespace for the custom metric the backup probe publishes. Custom
  # namespaces are free; CloudWatch charges only for the alarm and for metrics it
  # retains beyond the free tier, and one integer metric an hour does neither.
  metric_namespace = "DPX/Backups"
}

module "naming" {
  source = "../naming"

  for_each = local.naming_resources

  name        = each.value
  project     = var.project
  env         = var.env
  layer       = var.layer
  owner       = var.owner
  cost_center = var.cost_center
  component   = "observability"
}

locals {
  resource_tags = {
    for key, naming in module.naming : key => merge(naming.tags, var.extra_tags)
  }

  log_group_prefix = "/${var.project}/${var.env}/nodes"
}

# ---------------------------------------------------------------------------
# Which alarms can be built at all
# ---------------------------------------------------------------------------
# Every target below comes from an earlier layer, and not every environment has
# applied every layer yet: qa has no 30-cluster and no 40-edge. An alarm whose
# dimension does not exist does not fail at apply time, it fails at *evaluation*
# time and silently never enters ALARM, which is worse than not having it.

locals {
  # 30-cluster and 40-edge are resolved by the layer root through remote state and
  # passed in as null when the layer has not been applied.
  has_cluster = var.control_plane_instance_id != null
  has_edge    = var.alb_arn != null

  # All four instance-level / group-level checks need the cluster to exist.
  enabled = var.enable_alarms && local.has_cluster

  # AWS/ApplicationELB keys every metric on the load balancer's name, not its ARN:
  # arn:aws:elasticloadbalancing:ap-south-1:<acct>:loadbalancer/app/dpx-prod-alb/abc123
  # is dimensioned as "dpx-prod-alb/abc123". Deriving it from the ARN matters
  # because a wrong dimension is the worst kind of CloudWatch mistake: no datapoint
  # is ever published, the alarm stays green forever, and nothing in the output
  # looks wrong.
  #
  # Two strippings rather than a slice. split("/", arn) yields only FOUR elements
  # here, not nine - the arn:aws:...:loadbalancer prefix has no slashes in it - so
  # an index-based derivation is silently wrong by three.
  alb_dimension = var.alb_arn == null ? null : replace(
    replace(var.alb_arn, "/^.*:loadbalancer\\//", ""),
    "^app/", "",
  )
}
