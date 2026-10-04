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
  description = "AWS region. EventBridge Scheduler is a regional service and the schedule's IAM role must exist in the same region as the instances it starts."
  type        = string
  default     = "ap-south-1"
}

variable "extra_tags" {
  description = "Additional tags merged on top of the standard tag set."
  type        = map(string)
  default     = {}
}

# ------------------------------------------------------------------ toggles --

variable "enable_scheduling" {
  description = "Create the stop/start schedules. Off by default in prod and on in qa, which is the arrangement Infrastructure.MD specifies."
  type        = bool
  default     = false
}

variable "allow_prod_scheduling" {
  description = <<-EOT
    Explicit acknowledgement that enabling_scheduling = true in prod is intended.
    Infrastructure.MD says scheduled stop is qa-only, and a nightly prod shutdown
    triggered by a typo in a cron expression is not a mistake Terraform can undo -
    it is one nobody is awake to notice. So prod needs this set as well before any
    schedule will be created.
  EOT
  type        = bool
  default     = false
}

# ----------------------------------------------------------------- schedules --

variable "stop_schedule_expression" {
  description = "EventBridge schedule expression for the stop action. Defaults to 19:00 on Friday, which covers the weekend, plus 19:00 on Sunday so the week starts already running."
  type        = string
  default     = "cron(0 19 ? * SUN,FRI *)"
}

variable "start_schedule_expression" {
  description = "EventBridge schedule expression for the start action. Defaults to 08:00 Monday to Friday, one hour before a working day starts."
  type        = string
  default     = "cron(0 8 ? * MON-FRI *)"
}

# ------------------------------------------------------------------- targets --

variable "instance_ids" {
  description = "Instances to stop and start. In practice the qa NAT instance and the qa control plane."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.instance_ids : can(regex("^i-[0-9a-f]{8,17}$", id))])
    error_message = "Every entry must look like an EC2 instance id (i- followed by 8-17 hex characters)."
  }
}

variable "worker_asg_name" {
  description = "Worker ASG to scale to 0 on the stop schedule and back to its minimum on the start schedule. Null to leave the ASG alone - qa's group already sits at min 0 on its own, and a schedule that scales an already-zero group is a no-op that costs an invocation."
  type        = string
  default     = null
}

variable "asg_start_desired_capacity" {
  description = "Desired capacity the start schedule sets on the worker ASG. Read from 30-cluster's worker_min_size rather than hardcoded here, so the two cannot disagree."
  type        = number
  default     = 0

  validation {
    condition     = var.asg_start_desired_capacity >= 0 && var.asg_start_desired_capacity <= 10
    error_message = "asg_start_desired_capacity must be between 0 and 10."
  }
}

# --------------------------------------------------------------------- costs --

variable "flexible_time_window_enabled" {
  description = <<-EOT
    EventBridge Scheduler charges per invocation, and a flexible time window
    counts as a second invocation for every window it opens. Two schedules
    firing twice a week with a one-hour window would quietly double a small but
    permanent line item. Off, so each schedule costs exactly one invocation.
  EOT
  type        = bool
  default     = false
}

variable "flexible_time_window_minutes" {
  description = "Width of the flexible window, ignored unless flexible_time_window_enabled is true."
  type        = number
  default     = 15
}

variable "schedule_kms_key_arn" {
  description = <<-EOT
    Full ARN of a KMS key for encrypting the schedule definition at rest. Null
    leaves the attribute off the resource entirely, which makes EventBridge
    Scheduler use the AWS-managed aws/scheduler key - the right default here,
    because a customer-managed key needs an explicit kms:GenerateDataKey grant for
    the scheduler service and the payload is two instance ids.

    Note this is an ARN and not an alias: the provider validates the format at plan
    time and `alias/aws/scheduler` fails with
      "kms_key_arn" (alias/aws/scheduler) is an invalid ARN: arn: invalid prefix
  EOT
  type        = string
  default     = null
}
