# ---------------------------------------------------------------------------
# KMS keys
# ---------------------------------------------------------------------------
# Two customer-managed keys:
#   - EBS: encrypts node root volumes and gp3 PVCs (EBS CSI driver, Phase 7).
#   - SSM: encrypts SecureString parameters (kubeadm join token, kubeconfig,
#     Argo CD repo deploy key).
#
# Deliberately not Secrets Manager: the spec rules it out, and SSM
# Parameter Store SecureString with a customer-managed key covers the same
# need at a fraction of the cost.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_root_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
}

# Root delegation is enough on its own for direct KMS calls made by an IAM
# principal, such as the SSM SecureString writes the control plane performs.
data "aws_iam_policy_document" "kms" {
  statement {
    sid       = "EnableIAMUserPermissions"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [local.account_root_arn]
    }
  }
}

# The EBS key additionally needs an explicit grant to the EC2 service.
#
# Encrypting a volume with a customer-managed key is not an ordinary KMS call.
# EC2 has to create a grant on the key on behalf of the instance role, and that
# grant is only permitted if the key policy itself allows the call through the
# EC2 service. Root delegation does not cover it, because the request arrives
# from the ec2.<region>.amazonaws.com service principal rather than from the
# role.
#
# Without this statement, RunInstances fails with
#   Client.InvalidKMSKey.InvalidState: The KMS key provided is in an incorrect state
# which describes a key that is enabled and perfectly usable, and sends you
# looking at the wrong key. The AWS-managed aws/ebs key has an equivalent
# statement, which is why instances launched against it work.
data "aws_iam_policy_document" "kms_ebs" {
  statement {
    sid       = "EnableIAMUserPermissions"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [local.account_root_arn]
    }
  }

  statement {
    sid    = "AllowEbsEncryptionViaEc2"
    effect = "Allow"
    actions = [
      "kms:CreateGrant",
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:GenerateDataKey*",
      "kms:ReEncrypt*",
    ]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ec2.${var.aws_region}.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_kms_key" "ebs" {
  description             = "EBS volume encryption for ${var.project}-${var.env}."
  enable_key_rotation     = var.enable_key_rotation
  deletion_window_in_days = var.kms_deletion_window_in_days
  policy                  = data.aws_iam_policy_document.kms_ebs.json

  tags = module.naming["ebs-key"].tags
}

resource "aws_kms_alias" "ebs" {
  name          = "alias/${module.naming["ebs-key"].full_name}"
  target_key_id = aws_kms_key.ebs.key_id
}

resource "aws_kms_key" "ssm" {
  description             = "SSM SecureString encryption for ${var.project}-${var.env}."
  enable_key_rotation     = var.enable_key_rotation
  deletion_window_in_days = var.kms_deletion_window_in_days
  policy                  = data.aws_iam_policy_document.kms.json

  tags = module.naming["ssm-key"].tags
}

resource "aws_kms_alias" "ssm" {
  name          = "alias/${module.naming["ssm-key"].full_name}"
  target_key_id = aws_kms_key.ssm.key_id
}
