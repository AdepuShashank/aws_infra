output "state_bucket" {
  description = "S3 bucket holding all remote Terraform state for this environment."
  value       = aws_s3_bucket.state.id
}

output "state_bucket_arn" {
  description = "ARN of the state bucket."
  value       = aws_s3_bucket.state.arn
}

output "state_bucket_region" {
  description = "Region of the state bucket (required in the S3 backend block)."
  value       = data.aws_region.current.region
}

output "state_kms_key_arn" {
  description = "KMS key used to encrypt remote state."
  value       = aws_kms_key.state.arn
}

output "state_kms_alias" {
  description = "KMS alias of the state key."
  value       = aws_kms_alias.state.name
}

output "state_admin_role_arn" {
  description = "Role granting operators access to remote state objects."
  value       = aws_iam_role.state_admin.arn
}

output "github_oidc_provider_arn" {
  description = "GitHub Actions OIDC provider ARN. Null unless this state created it. The provider is account-global, so the environment that did not create it should read this ARN from the other environment's output rather than expect its own."
  value       = one(aws_iam_openid_connect_provider.github[*].arn)
}

output "github_plan_role_arn" {
  description = "Read-only planning role ARN for GitHub Actions."
  value       = local.plan_role_arn
}

output "github_apply_role_arn" {
  description = "Tag-scoped apply role ARN for GitHub Actions."
  value       = local.apply_role_arn
}

output "github_trusted_subjects" {
  description = "OIDC 'sub' claim values allowed to assume the plan/apply roles."
  value       = local.github_subjects
}

output "alerts_topic_arn" {
  description = "SNS topic used for budget breaches and CloudWatch alarms."
  value       = aws_sns_topic.alerts.arn
}

output "alerts_topic_name" {
  description = "Name of the alerts SNS topic."
  value       = aws_sns_topic.alerts.name
}

output "alert_email_subscription_pending" {
  description = "TRUE until alert_email has confirmed the SNS subscription. Budget alerts are not delivered while true."
  value       = aws_sns_topic_subscription.alert_email.pending_confirmation
}

output "budget_name" {
  description = "Name of the monthly cost budget."
  value       = aws_budgets_budget.monthly.name
}

output "budget_limit_usd" {
  description = "Monthly budget limit in USD."
  value       = var.monthly_budget_usd
}

output "budget_thresholds" {
  description = "Alert thresholds as percentages of the budget limit."
  value       = var.budget_threshold_percentages
}

output "aws_account_id" {
  description = "AWS account id resolved via STS (never hardcoded)."
  value       = data.aws_caller_identity.current.account_id
}