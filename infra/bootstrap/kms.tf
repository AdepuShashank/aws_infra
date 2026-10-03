# --------------------------------------------------------------- KMS for state ---
# The state bucket is encrypted with a dedicated customer-managed key rather than
# the AWS-managed aws/s3 key, so that key usage is auditable and the encryption
# context can be scoped to this project.

resource "aws_kms_key" "state" {
  description             = "Terraform remote state encryption for ${local.name_prefix}"
  deletion_window_in_days = var.kms_deletion_window_days
  enable_key_rotation     = true
  multi_region            = false
  key_usage               = "ENCRYPT_DECRYPT"
  tags                    = local.standard_tags
}

resource "aws_kms_alias" "state" {
  name          = local.kms_alias_name
  target_key_id = aws_kms_key.state.key_id
}

data "aws_iam_policy_document" "state_key" {
  # Root always retains the ability to recover/administer the key, otherwise a
  # lost key means unrecoverable state.
  statement {
    sid     = "AllowAccountAdministration"
    effect  = "Allow"
    actions = ["kms:*"]
    resources = [
      "*",
    ]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  # Operator / teardown role needs the key to read and repair state objects.
  # CI roles are intentionally NOT granted here: their KMS access lives in their
  # own identity policies (plan -> Decrypt, apply -> Encrypt/Decrypt). Granting
  # in the key policy too would create a cycle:
  #   key policy -> role -> role policy -> key
  statement {
    sid    = "AllowStateOperatorsToUseStateKey"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.state_admin.arn]
    }
  }
}

resource "aws_kms_key_policy" "state" {
  key_id = aws_kms_key.state.key_id
  policy = data.aws_iam_policy_document.state_key.json
}