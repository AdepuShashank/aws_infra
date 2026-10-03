# Bootstrap (Phase 1)

Account-level prerequisites that must exist before any environment layer can be
created: the remote state buckets, their KMS keys, the IAM roles that GitHub
Actions assumes to run plan/apply, the budget, and the cost alert topic.

## State separation (read this before the first apply)

This directory holds the Terraform for **both** environments, but the two sets of
resources are not the same ones. Prod and QA each get their own state bucket,
KMS key, budget and alerts topic, so a single default `terraform.tfstate` in
this directory would make Terraform believe QA resources were prod's and try to
destroy them.

Pass an explicit state file per environment. The flag is not optional:

`powershell
terraform init
terraform apply -auto-approve -input=false "-state=bootstrap-prod.tfstate" "-var-file=prod.tfvars"
terraform apply -auto-approve -input=false "-state=bootstrap-qa.tfstate"   "-var-file=qa.tfvars"
`

Quote the arguments: PowerShell otherwise mangles the `-state=` value.

`bootstrap-prod.tfstate` and `bootstrap-qa.tfstate` are gitignored local state
files. This layer intentionally keeps local state because it is what *creates*
the remote buckets; once it is applied, every layer under `infra/envs` uses the
S3 backend configured in its `backend.tf`.

## Budget scope

The monthly budget is account-wide by default (`budget_filter_tags = {}`). A
per-environment filter such as `tag:Env` is only accepted by AWS once `Env`
is activated as a **Cost Allocation Tag**, which needs
`ce:UpdateCostAllocationTagsStatus` on the account. Without that activation
AWS rejects the apply with::

    InvalidParameterException: ... tag:Env is not in the supported in cost
    budget dimension set: [PurchaseType, ...]

Until the tag is activated, leaving `budget_filter_tags` empty is deliberate:
prod and qa both measure total account spend, so the two budgets are not
independent. Activate the tags, then set the filter per environment.