# Variables shared by every layer in the prod environment.
#
# Everything in this file must be declared in each layer root's variables.tf,
# because every layer root calls modules/foundation. Layer-specific settings
# live next to their layer in <layer>/prod.tfvars.
#
# Plan from a layer root with:
#   terraform plan -input=false -var-file=..\common.tfvars -var-file=prod.tfvars

# ---------------------------------------------------------------- identity ---
project     = "dpx"
env         = "prod"
owner       = "platform-team"
cost_center = "cc-dpx-prod"
aws_region  = "ap-south-1"

# -------------------------------------------------------------------- tags ---
extra_tags = {
  Environment = "production"
  DataClass   = "internal"
}

# -------------------------------------------------------------------- edge ---
# Passed to modules/foundation in every layer so the provider and default tags
# are identical everywhere. Only 40-edge actually consumes them.
#
# Tighten this before pointing anything real at the ALB. 0.0.0.0/0 is only
# acceptable because this is a throwaway portfolio environment.
alb_allowed_cidrs = ["0.0.0.0/0"]

# No domain purchased yet -> no Route 53 hosted zone, no ACM certificate,
# no HTTPS listener. Set to a real zone name to switch DNS/HTTPS on.
domain_name = null