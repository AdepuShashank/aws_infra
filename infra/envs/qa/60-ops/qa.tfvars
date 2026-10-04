# 60-ops settings for qa.
#
# Applied with:
#   terraform apply -input=false "-var-file=..\common.tfvars" "-var-file=qa.tfvars"
#
# qa has 10-network and 20-security applied and nothing after that. This layer is
# therefore plannable today with a deliberately narrow footprint: the backup buckets,
# the alarm topic and the log groups exist, and the alarms that need a cluster do
# not. That is not a half-finished state, it is the honest one - see alarm_count and
# cluster_dependencies in the outputs.

# ------------------------------------------------------- 30-cluster state ---
# This layer's own state key is qa/60-ops/terraform.tfstate in the same bucket.
state_bucket = "dpx-tfstate-qa"

# --------------------------------------------------------------- encryption ---
# The qa EBS key. Same reasoning as prod: the node role's kms:GenerateDataKey grant
# in 20-security names the EBS key, and the node role is what uploads snapshots.
backup_kms_key_arn = "arn:aws:kms:ap-south-1:580857072251:key/f42c6d0c-d1f8-40d5-afea-11d68fc30de6"

# ---------------------------------------------------------------- alerting ---
alert_email = "shashank.adepu5@gmail.com"

# On. qa's ALB alarms stay absent until 40-edge exists, and the cluster alarms stay
# absent until 30-cluster does - both are created by `count` on a null input rather
# than by this flag.
enable_alarms = true

# Off until there is a control plane to install it on. The SSM association is
# created by `count` on the instance id anyway, so this is belt and braces: it keeps
# the intent legible instead of depending on a reader knowing that a null
# control_plane_instance_id suppresses the whole module section.
enable_cloudwatch_agent = false

# Same reasoning: the probe runs on the control plane and measures the age of a
# snapshot from the etcd bucket 30-cluster creates.
enable_backup_probe = false

# ----------------------------------------------------------------- backups ---
# The postgres bucket and the DLM policy are created regardless of the cluster, so
# qa has a working backup target the day 30-cluster is applied. The etcd bucket name
# is derived here rather than read from 30-cluster, because that layer has no state.
dlm_enabled = true

# --------------------------------------------------------------- scheduler ---
# On: qa is the environment Infrastructure.MD scopes scheduled stop to, and the NAT
# instance that already exists is the one thing here worth turning off on a weekend.
enable_scheduling     = true
allow_prod_scheduling = false

# 19:00 Friday and 19:00 Sunday, 08:00 Monday to Friday. Asia/Kolkata, set on the
# schedules themselves rather than left at UTC - a UTC reading of "19:00" means
# 00:30 IST, which is the sort of thing that looks right in a plan and is not.
stop_schedule_expression  = "cron(0 19 ? * SUN,FRI *)"
start_schedule_expression = "cron(0 8 ? * MON-FRI *)"

# The worker ASG rests at min 0 on its own, so there is nothing for a schedule to do
# with it, and 30-cluster has no state to read a group name from anyway. Turn this on
# when 30-cluster lands and the group's minimum is raised above 0.
manage_worker_asg          = false
asg_start_desired_capacity = 0
