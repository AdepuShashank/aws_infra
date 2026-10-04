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

# ------------------------------------------------------------------ alerting --

variable "alert_email" {
  description = "Address subscribed to the ops SNS topic. Left unconfirmed by Terraform - AWS sends a confirmation mail and the subscription only activates once the recipient clicks it. An unconfirmed subscription is not an error; check subscription_status on the output."
  type        = string

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.alert_email))
    error_message = "alert_email must be a valid email address."
  }
}

variable "enable_alarms" {
  description = "Create the CloudWatch alarms. Off is useful for the qa environment, where most of the checks are either permanently breaching (no cluster) or noise."
  type        = bool
  default     = true
}

variable "sns_kms_master_key_id" {
  description = "KMS key id applied to the topic's default encryption. alias/aws/sns rather than the account's own key, because the AWS-managed SNS key is the only one CloudWatch is guaranteed to be able to use."
  type        = string
  default     = "alias/aws/sns"
}

# --------------------------------------------------------- alarm thresholds --

variable "alb_5xx_threshold" {
  description = "HTTPCode_Target_5XX_Count sum per evaluation period before the ALB 5xx alarm fires. Deliberately a count and not a rate: this environment serves health checks as well as user traffic, so any 5xx at all is worth waking for."
  type        = number
  default     = 5
}

variable "etcd_snapshot_stale_minutes" {
  description = <<-EOT
    Age of the newest etcd snapshot, in minutes, at which the freshness alarm
    fires. The snapshot timer runs every 6 hours, so this is set to roughly one
    cycle plus slack: firing earlier would alarm on a normal cycle.
  EOT
  type        = number
  default     = 420
}

# ---------------------------------------------------------------- log groups --

variable "enable_agent" {
  description = "Install and configure the CloudWatch agent on the nodes through an SSM association. The IAM side of this was done in Phase 3; without it the node role's CloudWatchAgentServerPolicy grant has no consumer."
  type        = bool
  default     = true
}

variable "agent_log_retention_days" {
  description = "Retention for the log groups the agent ships to."
  type        = number
  default     = 30

  validation {
    condition = contains(
      [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365],
      var.agent_log_retention_days
    )
    error_message = "retention_in_days must be one of the values CloudWatch Logs accepts."
  }
}

# ------------------------------------------------- targets from earlier layers --
# Passed in rather than looked up by tag: the node role and the ASG both carry the
# same Project/Env/ManagedBy tags as the backup buckets and the KMS keys, so a tag
# lookup can silently return the wrong object type. Remote state cannot.

variable "control_plane_instance_id" {
  description = "Control plane instance id from 30-cluster, for the status-check alarm and the SSM probe. Null when 30-cluster has not been applied."
  type        = string
  default     = null
}

variable "worker_asg_name" {
  description = "Worker ASG name from 30-cluster, for the capacity-shortfall alarm. Null when 30-cluster has not been applied."
  type        = string
  default     = null
}

variable "alb_arn" {
  description = "ALB ARN from 40-edge, for the target-health and 5xx alarms. Null when 40-edge has not been applied."
  type        = string
  default     = null
}

# ------------------------------------------------------------ backup probing --

variable "etcd_backup_bucket_name" {
  description = "Etcd snapshot bucket the probe measures the age of. Read by the association's script through the node role."
  type        = string
}

variable "enable_backup_probe" {
  description = "Run an SSM association on the control plane that publishes the age of the newest etcd snapshot as a CloudWatch metric. This is the only thing that makes a silently-stopped backup timer visible."
  type        = bool
  default     = true
}

variable "probe_schedule" {
  description = "How often the backup probe runs. Hourly, so a stale-snapshot alarm has a datapoint an hour old rather than one from six hours ago."
  type        = string
  default     = "rate(1 hour)"
}

variable "probe_timeout_seconds" {
  description = "SSM association timeout. Long enough for the S3 listing and the metric write on a t4g.nano over the NAT instance."
  type        = number
  default     = 300
}
