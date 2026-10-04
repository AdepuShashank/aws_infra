variable "project" {
  description = "Project identifier used in resource names and tags."
  type        = string
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
  description = "This Terraform layer."
  type        = string
  default     = "60-ops"
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

variable "alb_allowed_cidrs" {
  description = "CIDR blocks allowed to reach the public ALB on 80/443."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "domain_name" {
  description = "Optional DNS name. null disables all Route 53 / ACM resources."
  type        = string
  default     = null
}

# ------------------------------------------------------- 30-cluster state ---
# 60-ops reads 10-network, 30-cluster and 40-edge from the same S3 bucket its own
# state lives in. Passing the bucket name in rather than hardcoding it keeps the
# layer from being pinned to one account's bucket naming.
variable "state_bucket" {
  description = "S3 bucket holding every layer's remote state for this environment."
  type        = string
}

# ----------------------------------------------- identifiers from earlier layers ---
# These three cannot be discovered at plan time in this project. See the comment at
# the top of main.tf for why: terraform_remote_state hard-fails against layers qa has
# never applied, and data.aws_instances only returns running instances while compute
# here is paused most of the time.
#
# Each is therefore declared here and set in <env>.tfvars, and each has a check block
# naming itself when it is missing. After replacing the control plane or the worker
# ASG, re-read them: the SSM association in observability keeps targeting the previous
# instance id until this layer is applied again, and SSM reports a terminated target
# as an orphaned association rather than as a failure.
variable "control_plane_instance_id" {
  description = "Control plane instance id, read from 30-cluster: `terraform output -no-color control_plane_instance_id`."
  type        = string
  default     = null
}

variable "worker_asg_name" {
  description = "Worker ASG name, read from 30-cluster: `terraform output -no-color worker_asg_name`."
  type        = string
  default     = null
}

variable "alb_arn" {
  description = "ALB ARN, read from 40-edge: `terraform output -no-color alb_arn`. Null until 40-edge is applied, and the two ALB alarms are then not created rather than created against nothing."
  type        = string
  default     = null
}

# -------------------------------------------------------------- encryption ---
# The EBS key from 20-security, read from the KMS alias rather than from
# 20-security's state, because the alias is the stable name and this layer would
# otherwise need a fourth remote-state read for one string.
#
# It is the EBS key specifically, and not a dedicated backups key, because 20-security
# grants the node role kms:GenerateDataKey on the EBS key only. Both backup buckets
# are written by the node role, so a separate backups key would mean every snapshot
# upload failing with AccessDenied - and the etcd timer reports success regardless,
# because its systemd oneshot does not check the exit code.
variable "backup_kms_key_arn" {
  description = "KMS key ARN used for SSE-KMS on both backup buckets. Must be the EBS key from 20-security."
  type        = string
}

# ---------------------------------------------------------------- alerting --

variable "alert_email" {
  description = "Address subscribed to the ops SNS topic. AWS sends a confirmation mail; nothing is delivered until it is clicked."
  type        = string
}

variable "enable_alarms" {
  description = "Create the CloudWatch alarms in 60-ops."
  type        = bool
  default     = true
}

variable "enable_cloudwatch_agent" {
  description = "Install and configure the CloudWatch agent on the control plane through an SSM association."
  type        = bool
  default     = true
}

variable "enable_backup_probe" {
  description = "Run the SSM association that publishes the age of the newest etcd snapshot, and alarm on it."
  type        = bool
  default     = true
}

# ----------------------------------------------------------------- backups --

variable "dlm_enabled" {
  description = "Create the DLM policy that reclaims EBS snapshots tagged for this environment."
  type        = bool
  default     = true
}

# --------------------------------------------------------------- scheduler --

variable "enable_scheduling" {
  description = "Create the EventBridge Scheduler stop/start schedules. Infrastructure.MD scopes this to qa."
  type        = bool
  default     = false
}

variable "allow_prod_scheduling" {
  description = "Acknowledgement that a prod schedule is intended. The module refuses to create one in prod without it."
  type        = bool
  default     = false
}

variable "stop_schedule_expression" {
  description = "EventBridge cron expression for the stop action."
  type        = string
  default     = "cron(0 19 ? * SUN,FRI *)"
}

variable "start_schedule_expression" {
  description = "EventBridge cron expression for the start action."
  type        = string
  default     = "cron(0 8 ? * MON-FRI *)"
}

variable "manage_worker_asg" {
  description = <<-EOT
    Whether the schedules should also set the worker ASG's desired capacity.
    Off by default: an environment whose ASG already rests at min 0 needs nothing
    scheduled, and the module's own guard skips the ASG schedules when no group name
    is available anyway.
  EOT
  type        = bool
  default     = false
}

variable "asg_start_desired_capacity" {
  description = "Desired capacity the start schedule sets on the worker ASG."
  type        = number
  default     = 0
}
