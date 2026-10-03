# ---------------------------------------------------------------------------
# VPC endpoints
# ---------------------------------------------------------------------------
# S3 gateway endpoint: keeps S3 traffic (etcd + Postgres backups, Argo CD repo,
# EBS snapshots) on the AWS backbone instead of routing it through the NAT
# instance. No hourly cost and no data-transfer charge.

resource "aws_vpc_endpoint" "s3" {
  count = var.enable_s3_gateway_endpoint ? 1 : 0

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  policy = data.aws_iam_policy_document.s3_endpoint.json

  tags = merge(local.tags, { Name = "${var.name}-s3" })
}

data "aws_iam_policy_document" "s3_endpoint" {
  # The Principal is "*" on purpose, and this is the part that is easy to get
  # wrong. A VPC endpoint policy is evaluated against the *session* principal
  # (arn:aws:sts::<account>:assumed-role/<role>/<session>), and that matches
  # neither arn:aws:iam::<account>:root nor arn:aws:iam::<account>:role/<role> -
  # both were tested against a live node and both denied every request:
  #   User: arn:aws:sts::580857072251:assumed-role/dpx-prod-node-role/i-... is not
  #   authorized to perform: s3:PutObject on resource:
  #   "arn:aws:s3:::dpx-prod-etcd-backups/etcd-....db" because no VPC endpoint
  #   policy allows the s3:PutObject action
  # while the node's IAM policy, the bucket policy and KMS all allowed it. EC2
  # also rejects a wildcard role principal (role/*) outright with
  # InvalidPolicyDocument, so "just allow the account" is not an option here.
  #
  # So the endpoint policy is used purely as a network containment control -
  # which buckets are reachable over this endpoint at all - and the real
  # authorization stays where it belongs: the node's IAM policy, the bucket
  # policy, and the KMS requirement on every write. Anonymous image pulls work
  # through exactly this mechanism.
  statement {
    sid    = "AllowProjectBackupBuckets"
    effect = "Allow"

    actions = [
      "s3:GetObject", "s3:GetObjectVersion", "s3:PutObject",
      "s3:DeleteObject", "s3:ListBucket", "s3:ListBucketVersions",
      "s3:GetBucketLocation",
    ]

    resources = concat(
      [for b in var.s3_endpoint_allowed_bucket_names : "arn:aws:s3:::${b}"],
      [for b in var.s3_endpoint_allowed_bucket_names : "arn:aws:s3:::${b}/*"],
    )

    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }

  # registry.k8s.io serves images from a CDN that redirects to a *public* S3
  # bucket in the caller's region. For ap-south-1 that is:
  #   prod-registry-k8s-io-ap-south-1.s3.dualstack.ap-south-1.amazonaws.com
  # The requests arrive anonymously, so without this statement every control-plane
  # image pull fails with 403 Forbidden:
  #   failed to pull and unpack image "registry.k8s.io/kube-apiserver:v1.36.5"
  # Read-only access to that one bucket is enough, and keeps the endpoint from
  # becoming a general-purpose public-read proxy for the VPC.
  statement {
    sid    = "AllowPublicReadOfK8sImageRegistry"
    effect = "Allow"

    actions = [
      "s3:GetObject", "s3:GetObjectVersion", "s3:ListBucket",
    ]

    resources = [
      "arn:aws:s3:::prod-registry-k8s-io-${data.aws_region.current.region}",
      "arn:aws:s3:::prod-registry-k8s-io-${data.aws_region.current.region}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }
}

# ---------------------------------------------------------------------------
# Optional interface endpoints
# ---------------------------------------------------------------------------
# These remove the NAT instance from the path for control-plane APIs and make
# SSM Session Manager work even with no NAT at all. They are OFF by default
# because each one costs roughly USD 0.01/hr (~USD 7.30/month) in ap-south-1 -
# six endpoints would nearly double the monthly baseline of this project.

resource "aws_vpc_endpoint" "interface" {
  count = length(var.interface_endpoint_services) > 0 ? length(var.interface_endpoint_services) : 0

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.${var.interface_endpoint_services[count.index]}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = aws_subnet.private[*].id
  security_group_ids = [aws_security_group.endpoint[0].id]

  tags = merge(local.tags, { Name = "${var.name}-${var.interface_endpoint_services[count.index]}" })
}

resource "aws_security_group" "endpoint" {
  count = length(var.interface_endpoint_services) > 0 ? 1 : 0

  name        = "${var.name}-vpce"
  description = "HTTPS from the private subnets to the interface VPC endpoints."
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS from private subnets"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = local.private_cidrs
  }

  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.name}-vpce" })

  lifecycle {
    create_before_destroy = true
  }
}