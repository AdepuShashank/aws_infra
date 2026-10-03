# ------------------------------------------------------------------ IAM roles ---
# No long-lived access keys exist anywhere in CI. GitHub Actions authenticates
# with an OIDC token and is exchanged for short-lived STS credentials.
#
#   plan  -> read-only everywhere + state read + SSM reads
#   apply -> administrator actions gated on the Env request/resource tag and on
#            a GitHub Environment (which can require reviewers + branch rules)

# ------------------------------------------------------- state operator role ---

data "aws_iam_policy_document" "state_admin_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

resource "aws_iam_role" "state_admin" {
  name                 = "${local.name_prefix}-state-admin"
  description          = "Operators / bootstrap teardown: manage the ${var.env} Terraform state bucket."
  assume_role_policy   = data.aws_iam_policy_document.state_admin_assume.json
  max_session_duration = 3600
  tags                 = local.standard_tags
}

data "aws_iam_policy_document" "state_admin" {
  statement {
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:ListBucketVersions",
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:DeleteBucket",
      "s3:GetBucketLocation",
      "s3:GetBucketVersioning",
      "s3:GetEncryptionConfiguration",
      "s3:PutEncryptionConfiguration",
      "s3:PutLifecycleConfiguration",
    ]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]
  }
  # NOTE: no kms:* statement here. The state key policy grants the KMS side to
  # this role, which avoids a cycle (role policy -> key -> key policy -> role).
}

resource "aws_iam_role_policy" "state_admin" {
  name   = "${local.name_prefix}-state-admin"
  role   = aws_iam_role.state_admin.id
  policy = data.aws_iam_policy_document.state_admin.json
}

# ----------------------------------------------------------- GitHub OIDC roles ---

resource "aws_iam_openid_connect_provider" "github" {
  # Gated separately from create_github_oidc on purpose. An OIDC provider is
  # account-global, not environment-scoped: the URL token.actions.githubusercontent.com
  # is identical in prod and qa, and IAM allows exactly one provider per URL per
  # account. Enabling it from both bootstrap states makes the second apply fail
  # with EntityAlreadyExists.
  #
  # Set create_github_oidc_provider = true in exactly ONE bootstrap state (qa is
  # the natural choice). The roles in the other environment reference the
  # provider by convention through local.oidc_provider_arn and need no change.
  count = var.create_github_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [var.github_oidc_thumbprint]
  tags            = local.standard_tags
}

locals {
  oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"

  # Index-free accessors so the state-bucket and KMS key policies can reference
  # these roles even when create_github_oidc = false (count = 0).
  plan_role_arn  = one(aws_iam_role.plan[*].arn)
  apply_role_arn = one(aws_iam_role.apply[*].arn)
}

data "aws_iam_policy_document" "github_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.github_subjects
    }
  }
}

# ---- plan role: read-only + state read -------------------------------------------

resource "aws_iam_role" "plan" {
  count = var.create_github_oidc ? 1 : 0

  # Env-scoped. IAM role names are account-global, so a bare
  # "${var.project}-tf-plan" would collide the moment both prod and qa enabled
  # create_github_oidc, and the second apply would fail with EntityAlreadyExists.
  name                 = "${var.project}-${var.env}-tf-plan"
  description          = "Read-only planning role for the ${var.env} environment. Assumed via GitHub Actions OIDC."
  assume_role_policy   = data.aws_iam_policy_document.github_trust.json
  max_session_duration = 3600
  tags                 = local.standard_tags

  lifecycle {
    precondition {
      condition     = !local.github_repo_is_placeholder
      error_message = "Set github_repository_owner / github_repository_name to real values before enabling create_github_oidc."
    }
  }
}

data "aws_iam_policy_document" "plan" {
  count = var.create_github_oidc ? 1 : 0

  # AWS-managed read-only baseline (EC2, ELB, ASG, S3, IAM read, CloudWatch read).
  statement {
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }

  # ReadOnlyAccess covers most of the API surface; these statements fill the gaps
  # that the managed policy does not include.
  statement {
    sid    = "ReadSsmParameters"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
      "ssm:DescribeParameters",
      "ssm:GetDocument",
      "ssm:DescribeDocument",
      "ssm:ListDocuments",
      "ssm:DescribeInstanceInformation",
      "ssm:ListAssociations",
      "ssm:DescribeAssociation",
      "ssm:ListCommands",
      "ssm:ListCommandInvocations",
      "ssm:GetCommandInvocation",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ReadKmsKeys"
    effect = "Allow"
    actions = [
      "kms:DescribeKey",
      "kms:ListKeys",
      "kms:ListAliases",
      "kms:GetKeyPolicy",
    ]
    resources = ["*"]
  }

  # Terraform must read the current state to produce a plan.
  statement {
    sid    = "ReadStateObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]
  }

  statement {
    sid    = "DecryptState"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [aws_kms_key.state.arn]
  }
}

resource "aws_iam_role_policy_attachment" "plan_read_only" {
  count = var.create_github_oidc ? 1 : 0

  role       = aws_iam_role.plan[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "plan_extra" {
  count = var.create_github_oidc ? 1 : 0

  # Inline policy names must also be unique per role, and the roles are now
  # env-scoped, so this follows the same pattern.
  name   = "${var.project}-${var.env}-tf-plan-extra"
  role   = aws_iam_role.plan[0].id
  policy = data.aws_iam_policy_document.plan[0].json
}

# ---- apply role: admin scoped to this environment by tag -------------------------

data "aws_iam_policy_document" "apply" {
  count = var.create_github_oidc ? 1 : 0

  statement {
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }

  statement {
    # Administrator scoped by tag: only resources created for this environment,
    # and only ones that carry the Env request tag, are reachable.
    effect    = "Allow"
    actions   = ["*"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Env"
      values   = [var.env]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Env"
      values   = [var.env]
    }
  }

  # Terraform must read/write the state lockfile and state objects.
  statement {
    sid    = "ManageStateObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]
  }

  statement {
    sid    = "UseStateKey"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:Encrypt",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = [aws_kms_key.state.arn]
  }

  # Managed policy attachment for cross-account / service scenarios.
  dynamic "statement" {
    for_each = var.apply_role_admin_actions

    content {
      sid       = "ExtraAdminActions"
      effect    = "Allow"
      actions   = [statement.value]
      resources = ["*"]
    }
  }
}

resource "aws_iam_role" "apply" {
  count = var.create_github_oidc ? 1 : 0

  name                 = "${var.project}-tf-apply-${var.env}"
  description          = "Apply role scoped to the ${var.env} environment via request/resource tags. Assumed via GitHub Actions OIDC."
  assume_role_policy   = data.aws_iam_policy_document.github_trust.json
  max_session_duration = 3600
  tags                 = local.standard_tags

  lifecycle {
    precondition {
      condition     = !local.github_repo_is_placeholder
      error_message = "Set github_repository_owner / github_repository_name before enabling create_github_oidc."
    }
  }
}

resource "aws_iam_role_policy" "apply" {
  count = var.create_github_oidc ? 1 : 0

  name   = "${var.project}-tf-apply-${var.env}"
  role   = aws_iam_role.apply[0].id
  policy = data.aws_iam_policy_document.apply[0].json
}