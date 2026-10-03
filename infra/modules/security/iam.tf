# ---------------------------------------------------------------------------
# Node instance profile
# ---------------------------------------------------------------------------
# One role for both control plane and workers. They need the same capabilities:
# SSM for access, Parameter Store for the join token and kubeconfig, EBS for the
# CSI driver, S3 for backups, CloudWatch for the agent.

locals {
  aws_managed_policies = {
    ssm = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
    # Note the service-role/ path. There is also a customer-managed-looking
    # AmazonEBSCSIDriverPolicyV2 at the policy root; V2 is the EKS addon variant
    # and the service-role path is the one intended for self-managed nodes.
    ebs_csi    = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
    cloudwatch = "arn:${data.aws_partition.current.partition}:iam::aws:policy/CloudWatchAgentServerPolicy"
  }
}

resource "aws_iam_role" "node" {
  name        = module.naming["node-role"].full_name
  description = "Kubernetes node role for ${var.project}-${var.env}. SSM access only, no SSH keys."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = module.naming["node-role"].tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = local.aws_managed_policies

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

data "aws_iam_policy_document" "node" {
  # Parameter Store, scoped to this project's prefix. The spec called for
  # read/write under /<env>/k8s/* because the control plane regenerates the
  # kubeadm join token every ~30 minutes and pushes it there for workers.
  statement {
    sid = "ParameterStoreRead"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
      "ssm:DescribeParameters",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_path_prefix}/*"]
  }

  statement {
    sid = "ParameterStoreWrite"
    actions = [
      "ssm:PutParameter",
      "ssm:DeleteParameter",
      "ssm:LabelParameter",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_path_prefix}/*"]
  }

  # Parameter Store encrypts SecureString values with the SSM key on write, so
  # writing one needs kms:GenerateDataKey in addition to decrypting on read.
  #
  # This is why the write statement above is not sufficient on its own: a node
  # with ssm:PutParameter but only kms:Decrypt fails at PutParameter with
  # AccessDeniedException, which surfaces in cloud-init as a silent failure
  # because the join-token timer swallows its own errors.
  statement {
    sid    = "SSMParameterEncryption"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:Encrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]
    resources = [aws_kms_key.ssm.arn]
  }

  # The EBS CSI driver (Phase 7) issues CreateGrant/Decrypt against the EBS key
  # for every encrypted volume it provisions.
  #
  # GenerateDataKey and Encrypt are here for the etcd snapshot uploads, not for
  # the CSI driver. `aws s3 cp --sse aws:kms` has S3 call GenerateDataKey on the
  # caller's behalf, so without them every snapshot upload fails with
  # AccessDeniedException while the snapshot timer itself reports success.
  statement {
    sid = "EBSKeyUsage"
    actions = [
      "kms:Decrypt",
      "kms:Encrypt",
      "kms:GenerateDataKey",
      "kms:GenerateDataKeyWithoutPlaintext",
      "kms:DescribeKey",
      "kms:CreateGrant",
    ]
    resources = [aws_kms_key.ebs.arn]
  }

  # Encrypted volumes: describe, snapshot and delete the snapshots the driver
  # creates, plus the volume-modification calls its controller needs.
  statement {
    sid = "EBSVolumeManagement"
    actions = [
      "ec2:CreateSnapshot",
      "ec2:CreateSnapshots",
      "ec2:CreateTags",
      "ec2:DeleteSnapshot",
      "ec2:DeleteTags",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeInstances",
      "ec2:DescribeSnapshots",
      "ec2:DescribeTags",
      "ec2:DescribeVolumes",
      "ec2:DescribeVolumesModifications",
    ]
    resources = ["*"]
  }

  # S3 access is limited to the two backup buckets. The control plane writes
  # etcd snapshots and CloudNativePG writes WAL/base backups. Everything else in
  # the account is out of reach, including the Terraform state buckets.
  statement {
    sid = "EtcdBackupBucket"
    actions = [
      "s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket", "s3:GetObjectVersion",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::${var.etcd_backup_bucket_name}",
      "arn:${data.aws_partition.current.partition}:s3:::${var.etcd_backup_bucket_name}/*",
    ]
  }

  statement {
    sid = "PostgresBackupBucket"
    actions = [
      "s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket", "s3:GetObjectVersion",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::${var.postgres_backup_bucket_name}",
      "arn:${data.aws_partition.current.partition}:s3:::${var.postgres_backup_bucket_name}/*",
    ]
  }

  statement {
    sid       = "SSMParameterPrefixTagging"
    actions   = ["ssm:AddTagsToResource", "ssm:RemoveTagsFromResource"]
    resources = ["arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_path_prefix}/*"]
  }
}

resource "aws_iam_role_policy" "node" {
  name   = module.naming["node-role"].full_name
  role   = aws_iam_role.node.id
  policy = data.aws_iam_policy_document.node.json
}

resource "aws_iam_instance_profile" "node" {
  name = module.naming["node-profile"].full_name
  role = aws_iam_role.node.name

  tags = module.naming["node-profile"].tags
}
