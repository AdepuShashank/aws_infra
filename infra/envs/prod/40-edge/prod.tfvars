# Phase 5 (40-edge) settings for prod.
#
# Applied with:
#   terraform plan -input=false "-var-file=..\common.tfvars" "-var-file=prod.tfvars"

# No domain is bought yet, so common.tfvars leaves domain_name = null and this
# layer creates no Route 53 records and no ACM certificate. The ALB's own DNS
# name over HTTP is the only endpoint, which is also what a fresh checkout should
# be able to validate against.

# Traefik's HTTP NodePort. HTTPS terminates at the ALB, so this is the only port
# the target group needs. Must match traefik_nodeports in ../20-security/prod.tfvars.
traefik_http_nodeport = 30080

# Off until a domain exists. enable_https without a domain serves a generated
# self-signed certificate, which proves the listener works and produces a browser
# warning on every request - so it stays off until there is something to prove.
enable_https             = false
enable_redirect_to_https = false

# See the module header: this protects the environment's only entry point from a
# mistyped destroy. Turning it off means `terraform destroy` can take the ALB with
# it, which is occasionally what you want in qa and almost never what you want here.
alb_deletion_protection = true

# Access logging is billed per request and this environment serves mostly health
# checks. Off until there is a reason to look at them.
alb_access_logs_bucket = null
