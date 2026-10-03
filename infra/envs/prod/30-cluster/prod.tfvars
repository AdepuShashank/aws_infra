# Phase 4 (30-cluster) settings for prod.
#
# Applied with:
#   terraform plan -input=false "-var-file=..\common.tfvars" "-var-file=prod.tfvars"

compute_enabled = false

# AMI resolution. Canonical has not published
# /aws/service/canonical/ubuntu/server/24.04/.../arm64/... in ap-south-1, so the
# SSM path is left empty and the module resolves the newest available
# ubuntu-noble-24.04-arm64-server image with DescribeImages. That tracks Ubuntu's
# point releases, but the AMI is still pinned into the launch template, so the
# cluster only changes images when this layer is re-applied.
ami_ssm_parameter = ""
ami_id_override   = ""

# Kubernetes 1.36.5, the newest minor at the time this was written. Pinned rather
# than floating: kubeadm refuses to work across a minor-version skew, and a
# silent upgrade of the control plane would take the workers with it.
kubernetes_version = "1.36.5"
cluster_name       = "dpx-prod"

# Pod and service CIDRs. Both must stay disjoint from the VPC (10.10.0.0/16) and
# from each other; the module asserts all three relationships.
pod_cidr     = "10.200.0.0/16"
service_cidr = "10.96.0.0/12"

# .10 in the first private subnet (10.10.10.0/24), which resolves to 10.10.10.10.
# This address is the kubeadm controlPlaneEndpoint: it is what every worker's
# kubeconfig and the join command point at, and it survives control-plane
# replacement because it lives on its own ENI.
control_plane_fixed_ip_offset = 10

# t4g.small, not t4g.medium, for the same reason. Corrected vCPU arithmetic:
# every T4g size from nano up to large has 2 vCPUs (t4g.nano 2, t4g.small 2,
# t4g.medium 2, t4g.large 2). Infrastructure.MD's sizing notes assumed 1 vCPU for
# the small sizes, which understates the real cost of the account's capacity.
control_plane_instance_type    = "t4g.small"
control_plane_root_volume_size = 30

# One on-demand worker, scaling to two. NOT the MD's default of 2/3, which this
# account cannot run:
#
#   NAT t4g.nano  2
#   CP  t4g.small 2
#   2 workers     4
#   --------------
#   total         8   == the account's on-demand vCPU limit of 8
#
# and landing exactly on the limit is not viable either. EC2 rejects the launch
# with VcpuLimitExceeded, but only on some of the attempts - a scale-out to 8
# succeeded once, the same scale-out failed minutes later - so an ASG pinned to
# the limit produces a group that is sometimes whole and sometimes missing a
# node, with no warning. A cluster whose worker count is a coin flip is worse
# than one with a single worker, so the floor is 1 and the ceiling is 2.
#
# At min 1 prod consumes 6 of 8 vCPU, which leaves exactly one instance's worth
# of headroom. That headroom is what qa competes for: qa's NAT plus control
# plane is 4 vCPU, so qa compute only fits while prod is at 1 worker, and never
# at the same time as a prod scale-out.
#
# Restoring 2/3 needs an on-demand vCPU quota increase to 16. See
# docs/quota.md.
worker_instance_types   = ["t4g.medium"]
worker_min_size         = 1
worker_max_size         = 2
worker_root_volume_size = 30

# Spot is off in prod. Spot Graviton capacity is reclaimed on roughly two
# minutes notice, and a reclaimed node takes every non-DaemonSet pod on it with
# it. That is acceptable for disposable qa workloads and not for prod.
enable_spot_workers = false

# Target group from 40-edge, so the worker ASG registers its instances and the
# ALB health check has something to check. Passed in rather than looked up because
# the dependency is circular: a target group needs instances, and the instances
# need the target group. See infra/envs/prod/40-edge/main.tf for the ordering.
alb_target_group_arns = ["arn:aws:elasticloadbalancing:ap-south-1:580857072251:targetgroup/dpx-prod-alb-tg/2064ef1506b3c01e"]

# Must match the name 20-security grants the node role S3 access to.
etcd_backup_bucket_name = "dpx-prod-etcd-backups"
