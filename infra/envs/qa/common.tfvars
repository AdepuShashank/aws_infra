# Variables shared by every layer in the qa environment.
#
# Everything in this file must be declared in each layer root's variables.tf,
# because every layer root calls modules/foundation. Layer-specific settings
# live next to their layer in <layer>/qa.tfvars.
#
# Plan from a layer root with:
#   terraform plan -input=false -var-file=..\common.tfvars -var-file=qa.tfvars

# ---------------------------------------------------------------- identity ---
project     = "dpx"
env         = "qa"
owner       = "platform-team"
cost_center = "cc-dpx-qa"
aws_region  = "ap-south-1"

# -------------------------------------------------------------------- tags ---
extra_tags = {
  Environment = "qa"
  DataClass   = "internal"
}

# -------------------------------------------------------------------- edge ---
# Passed to modules/foundation in every layer so the provider and default tags
# are identical everywhere. Only 40-edge actually consumes them.
alb_allowed_cidrs = ["0.0.0.0/0"]

# No domain purchased yet -> no Route 53, no ACM, no HTTPS listener.
domain_name = null