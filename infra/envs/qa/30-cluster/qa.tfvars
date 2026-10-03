# Phase 4 (30-cluster) settings for qa.
#
# Applied with:
#   terraform plan -input=false "-var-file=..\common.tfvars" "-var-file=qa.tfvars"

compute_enabled = false

# AMI resolution, same reasoning as prod. See prod.tfvars.
ami_ssm_parameter = ""
ami_id_override   = ""

kubernetes_version = "1.36.5"

# The cluster name carries the environment so the two clusters are
# distinguishable in kubectl output and in every object they create. Not "dpx":
# two clusters answering to the same name makes it far too easy to point kubectl
# at the wrong one.
cluster_name = "dpx-qa"

# Pod and service CIDRs must stay disjoint from the VPC (10.20.0.0/16) and from
# each other; the module asserts all three relationships.
pod_cidr     = "10.200.0.0/16"
service_cidr = "10.96.0.0/12"

# .10 in the first private subnet (10.20.10.0/24), which resolves to 10.20.10.10.
control_plane_fixed_ip_offset = 10

# t4g.small, per the Infrastructure.MD sizing table. The account's standard
# instance-bucket limit is 8 vCPU, shared with the prod cluster and both NAT
# instances, so t4g.medium here is what pushes prod's workers over the limit.
control_plane_instance_type    = "t4g.small"
control_plane_root_volume_size = 30

# Spot workers, sized as the MD specifies. Held at min 0 rather than 1 so the
# group starts empty and only consumes capacity when qa is actually being used:
#
#   NATs 1 + prod (cp 1 + 2 x medium 4) + qa cp 1 = 7 of 8 vCPU
#
# A standing qa worker at t4g.medium would be the 9th and would fail to launch
# with VcpuLimitExceeded. Scale the group up when qa needs it and prod is small,
# and down again afterwards.
worker_instance_types   = ["t4g.medium"]
worker_min_size         = 0
worker_max_size         = 2
worker_root_volume_size = 30

# Spot is on in qa. Spot Graviton capacity is reclaimed on roughly two minutes
# notice, which exercises the ASG's replacement path continuously instead of
# leaving it untested until the first real interruption.
enable_spot_workers = true

worker_spot_instance_types = ["t4g.medium", "t4g.large"]

# Empty until 40-edge creates the ALB target group.
alb_target_group_arns = []

# Must match the name 20-security grants the node role S3 access to.
etcd_backup_bucket_name = "dpx-qa-etcd-backups"
