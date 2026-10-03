# Bootstrap values for the PROD environment.
# Usage:  terraform -var-file=prod.tfvars plan
# Contains no secrets. Credentials come from the environment / OIDC, never a file.

project     = "dpx"
env         = "prod"
aws_region  = "ap-south-1"
owner       = "platform-team"
cost_center = "cc-dpx"

# ------------------------------------------------------------------- state ---
# prod keeps state through teardown/rebuild cycles - never set force_destroy here.
state_noncurrent_retention_days = 90
kms_deletion_window_days        = 14

# ------------------------------------------------------------------ budgets ---
monthly_budget_usd           = 20
budget_threshold_percentages = [80, 100]
alert_email                  = "shashank.adepu5@gmail.com"

# ----------------------------------------------------------------- GitHub ---
# TODO: replace with the real repository once it exists, then flip
# create_github_oidc to true.
create_github_oidc = false
# The OIDC provider is account-global, so this stays false in prod. qa.tfvars
# creates it; prod references it by convention.
create_github_oidc_provider = false
github_repository_owner     = "REPLACE_ME"
github_repository_name      = "REPLACE_ME"
github_allowed_branches     = ["main"]
github_allowed_environments = ["prod"]