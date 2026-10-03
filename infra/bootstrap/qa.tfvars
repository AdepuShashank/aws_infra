# Bootstrap values for the QA environment.
# Usage:  terraform -var-file=qa.tfvars plan

project     = "dpx"
env         = "qa"
aws_region  = "ap-south-1"
owner       = "platform-team"
cost_center = "cc-dpx"

# ------------------------------------------------------------------- state ---
state_noncurrent_retention_days = 30
kms_deletion_window_days        = 7

# ------------------------------------------------------------------ budgets ---
monthly_budget_usd           = 10
budget_threshold_percentages = [80, 100]
alert_email                  = "shashank.adepu5@gmail.com"

# ----------------------------------------------------------------- GitHub ---
# TODO: replace with the real repository once it exists.
create_github_oidc = false
# The OIDC provider is account-global, so this stays false in prod. qa.tfvars
# creates it; prod references it by convention.
create_github_oidc_provider = false
github_repository_owner     = "REPLACE_ME"
github_repository_name      = "REPLACE_ME"
github_allowed_branches     = ["main"]
github_allowed_environments = ["qa"]