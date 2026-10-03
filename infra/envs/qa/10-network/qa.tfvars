# Phase 2 (10-network) settings for qa.
#
# Applied with:
#   terraform plan -input=false -var-file=..\common.tfvars -var-file=qa.tfvars

compute_enabled = false

# 10.20.0.0/16 keeps qa visually and numerically separate from prod's
# 10.10.0.0/16, and stays clear of the pod CIDR (10.200.0.0/16) and the
# service CIDR (10.96.0.0/12). The module asserts this at plan time.
vpc_cidr = "10.20.0.0/16"

# qa runs at small scale and is torn down most of the week, so one AZ is
# cheaper. But the control plane needs redundancy if it is left running, and
# the platform expects two zones, so keep 2 here.
availability_zone_count = 2

# Same NAT approach as prod; see docs/adr/0001-fck-nat.md.
nat_instance_type = "t4g.nano"

# Endpoints are the main per-environment cost lever: at roughly USD 7.30/month
# each they dominate a small budget. Keep empty unless qa must run with the NAT
# instance stopped, which is not currently a scenario.
interface_endpoint_services = []

# Flow logs stay off in qa; it is the environment that gets torn down anyway.
enable_flow_logs        = false
flow_log_retention_days = 7