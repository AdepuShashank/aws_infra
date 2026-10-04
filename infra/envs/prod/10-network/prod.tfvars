# Phase 2 (10-network) settings for prod.
#
# Applied with:
#   terraform plan -input=false -var-file=..\common.tfvars -var-file=prod.tfvars

compute_enabled = true

# 10.10.0.0/16 must not overlap the pod CIDR (10.200.0.0/16) or the service
# CIDR (10.96.0.0/12). The module asserts this at plan time.
vpc_cidr = "10.10.0.0/16"

# Two AZs: one for the control plane plus each worker's zone.
availability_zone_count = 2

# NAT egress. One t4g.nano serves every private subnet; see
# docs/adr/0001-fck-nat.md for why this is a single aws_instance and what that
# costs in resilience.
nat_instance_type = "t4g.nano"

# Interface VPC endpoints cost about USD 7.30/month each in ap-south-1, so the
# default is to rely on the NAT instance for egress and stay off the S3 gateway
# endpoint only. The S3 gateway endpoint is free and always on.
interface_endpoint_services = []

# VPC flow logs run about USD 0.50 per GB ingested. Off by default; turn on for
# prod only when an incident justifies the bill.
enable_flow_logs        = false
flow_log_retention_days = 14