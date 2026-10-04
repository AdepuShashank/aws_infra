# 60-ops settings for prod.
#
# Applied with:
#   terraform apply -input=false "-var-file=..\common.tfvars" "-var-file=prod.tfvars"
#
# No compute is touched by this layer. Everything here is buckets, alarms, log
# groups and schedules, so it can be applied while prod is paused - which is the
# point, because it means the observability baseline exists before the bill starts.

# ------------------------------------------------------- 30-cluster state ---
# This layer's own state key is prod/60-ops/terraform.tfstate in the same bucket.
# The bucket name is passed in rather than hardcoded so the layer is not pinned to
# one account's naming.
state_bucket = "dpx-tfstate-prod"

# ------------------------------------------- identifiers from earlier layers ---
# These cannot be looked up at plan time in this project - see the header of main.tf
# for why - so they are written down here. After replacing the control plane, re-read
# the first value and re-apply this layer, or the CloudWatch agent and the backup
# probe keep attaching themselves to the old instance id.
control_plane_instance_id = "i-0b7d611942ed0a2c3"
worker_asg_name           = "dpx-prod-worker-asg-0b6505d5c8256cc522802021bb"
alb_arn                   = "arn:aws:elasticloadbalancing:ap-south-1:580857072251:loadbalancer/app/dpx-prod-alb/5792a264a9326a21"

# -------------------------------------------------------------- encryption ---
# alias/dpx-prod-kms-ebs. The EBS key, not a backups key: 20-security grants the
# node role kms:GenerateDataKey on the EBS key, and the node role is what uploads
# every etcd snapshot. A different key here would break those uploads at 03:00
# rather than at apply time.
backup_kms_key_arn = "arn:aws:kms:ap-south-1:580857072251:key/df15a379-3322-46a5-8360-ad9370be87c1"

# ---------------------------------------------------------------- alerting ---
# Same address as infra/bootstrap uses for budget alerts. The confirmation mail
# has to be clicked separately for each topic, so expect two.
alert_email = "shashank.adepu5@gmail.com"

enable_alarms = true

# The IAM grant for the CloudWatch agent exists in 20-security and nothing has
# used it until now. Turning this on installs and configures the agent over SSM.
enable_cloudwatch_agent = true

# Publishes the age of the newest etcd snapshot as a CloudWatch metric, so a
# snapshot timer that silently stopped becomes an alarm instead of a surprise.
enable_backup_probe = true

# ----------------------------------------------------------------- backups ---
dlm_enabled = true

# --------------------------------------------------------------- scheduler ---
# Both false. Infrastructure.MD scopes scheduled stop to qa, and a prod schedule
# that fires at 19:00 because of a typo is not something Terraform can undo at
# 03:00. Flip enable_scheduling only after allow_prod_scheduling is also true.
enable_scheduling     = false
allow_prod_scheduling = false

# Only consulted if both of the above are turned on.
stop_schedule_expression  = "cron(0 19 ? * SUN,FRI *)"
start_schedule_expression = "cron(0 8 ? * MON-FRI *)"
