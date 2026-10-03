variable "project" {
  description = "Project identifier used in resource names and tags."
  type        = string
  default     = "dpx"
}

variable "env" {
  description = "Environment this bootstrap run provisions for. Bootstrap is run once per environment."
  type        = string

  validation {
    condition     = contains(["prod", "qa"], var.env)
    error_message = "env must be one of: prod, qa."
  }
}

variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "ap-south-1"
}

variable "owner" {
  description = "Accountable owner tag value."
  type        = string
  default     = "platform-team"
}

variable "cost_center" {
  description = "Cost allocation tag value."
  type        = string
  default     = "cc-dpx"
}

variable "extra_tags" {
  description = "Additional tags merged on top of the standard tag set."
  type        = map(string)
  default     = {}
}

# --------------------------------------------------------------- state bucket ---

variable "state_bucket_name" {
  description = "Name of the S3 state bucket. Defaults to <project>-tfstate-<env>. Must be globally unique."
  type        = string
  default     = null
}

variable "state_noncurrent_retention_days" {
  description = "Days to keep noncurrent (previous) versions of state objects before expiry."
  type        = number
  default     = 30

  validation {
    condition     = var.state_noncurrent_retention_days >= 7 && var.state_noncurrent_retention_days <= 365
    error_message = "state_noncurrent_retention_days must be between 7 and 365."
  }
}

variable "state_abort_multipart_days" {
  description = "Days after which incomplete multipart uploads in the state bucket are aborted."
  type        = number
  default     = 7
}

variable "kms_deletion_window_days" {
  description = "Waiting period before the state KMS key is deleted. Blocks accidental key loss."
  type        = number
  default     = 7

  validation {
    condition     = var.kms_deletion_window_days >= 7 && var.kms_deletion_window_days <= 30
    error_message = "kms_deletion_window_days must be between 7 and 30."
  }
}

# ------------------------------------------------------------------ GitHub OIDC ---

variable "create_github_oidc" {
  description = "Create the per-environment plan/apply IAM roles. Safe to enable in both prod and qa because the role names are env-scoped."
  type        = bool
  default     = false
}

variable "create_github_oidc_provider" {
  description = <<-EOT
    Create the GitHub Actions OIDC provider. The provider is account-global and
    the URL is the same in every environment, so this must be true in exactly
    ONE bootstrap state; enabling it in both prod and qa makes the second apply
    fail with EntityAlreadyExists. Leave false where the provider already
    exists, or when create_github_oidc is false entirely.
  EOT
  type        = bool
  default     = false
}

variable "github_repository_owner" {
  description = "GitHub org or user that owns the infrastructure repository."
  type        = string
  default     = "REPLACE_ME"
}

variable "github_repository_name" {
  description = "Name of the GitHub repository holding this Terraform code."
  type        = string
  default     = "REPLACE_ME"
}

variable "github_oidc_thumbprint" {
  description = "SHA-1 thumbprint of the GitHub Actions OIDC certificate (DigiCert Global Root G2)."
  type        = string
  default     = "6938fd4d98bab03faadb97b34396831e3780aea1"
}

variable "github_allowed_branches" {
  description = "Branches whose workflow runs may assume the roles (matched against the OIDC 'sub' claim)."
  type        = list(string)
  default     = ["main"]
}

variable "github_allowed_environments" {
  description = "GitHub Environments whose deployment jobs may assume the roles. Empty means environment subjects are not trusted."
  type        = list(string)
  default     = []

  validation {
    # Only enforced when the roles actually exist. An unconditional
    # length() > 0 check would fail every plan of the current configuration,
    # which defaults to create_github_oidc = false and an empty list.
    condition     = !var.create_github_oidc || length(var.github_allowed_environments) > 0
    error_message = "When create_github_oidc = true, list at least one GitHub Environment (for example this env's name) - environment-gated workflows are the safe path for apply."
  }
}

variable "apply_role_admin_actions" {
  description = "Actions the per-env apply role is allowed to perform outside AWS managed policy boundaries. Empty = AdministratorAccess gated on request tags."
  type        = list(string)
  default     = []
}

# -------------------------------------------------------------------- budgets ---

variable "monthly_budget_usd" {
  description = "Monthly cost budget for this environment in USD. Alerts fire at the configured percentages of this value."
  type        = number

  validation {
    condition     = var.monthly_budget_usd > 0
    error_message = "monthly_budget_usd must be greater than zero."
  }
}

variable "budget_threshold_percentages" {
  description = "Percentages of the budget at which an alert is published to the SNS topic."
  type        = list(number)
  default     = [80, 100]

  validation {
    condition     = length(var.budget_threshold_percentages) > 0 && alltrue([for p in var.budget_threshold_percentages : p > 0 && p <= 100])
    error_message = "budget_threshold_percentages must be non-empty and within (0, 100]."
  }
}

variable "alert_email" {
  description = "Email address subscribed to the budget/alert SNS topic. Requires manual confirmation of the SNS subscription email."
  type        = string

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[a-zA-Z]{2,}$", var.alert_email))
    error_message = "alert_email must be a valid email address."
  }
}
variable "budget_filter_tags" {
  description = <<-EOT
    Cost filter for the monthly budget, as tag-key => tag-value. Empty (the
    default) means no cost_filter block at all, so the budget measures the whole
    account.

    Populating this requires every key to be activated as an AWS Cost Allocation
    Tag, which needs ce:UpdateCostAllocationTagsStatus once at the account
    level. Until that is done the apply fails with
    "tag:<key> is not in the supported in cost budget dimension set".
  EOT
  type        = map(string)
  default     = {}
}