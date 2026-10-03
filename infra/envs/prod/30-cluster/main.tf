# Shared identity + provider wiring for this layer.
# Kept in a module so all 6 layers x 2 envs stay identical.
module "foundation" {
  source = "../../../modules/foundation"

  project           = var.project
  env               = var.env
  layer             = var.layer
  owner             = var.owner
  cost_center       = var.cost_center
  aws_region        = var.aws_region
  extra_tags        = var.extra_tags
  alb_allowed_cidrs = var.alb_allowed_cidrs
  domain_name       = var.domain_name
}

# ---------------------------------------------------------------------------
# Cross-layer lookup
# ---------------------------------------------------------------------------
# 10-network and 20-security are already applied, so their outputs live in their
# own state keys. Reading them via state would require a second backend and a
# data "terraform_remote_state" block, which couples this layer's plan to those
# files being present locally. Every other layer here resolves by tag lookup
# instead, so this one does the same for consistency.
#
# Consequence: `terraform plan` in this layer fails with "no matching VPC found"
# until 10-network and 20-security have been applied. That is intentional.

data "aws_vpcs" "this" {
  filter {
    name   = "tag:Project"
    values = [var.project]
  }

  filter {
    name   = "tag:Env"
    values = [var.env]
  }

  filter {
    name   = "tag:ManagedBy"
    values = ["terraform"]
  }

  filter {
    name   = "tag:Component"
    values = ["network"]
  }
}

locals {
  # Unambiguous by construction. Zero matches means 10-network has not been
  # applied; two or more means two VPCs carry the same tags, and the cluster
  # would silently land in the wrong one.
  vpc_id = length(data.aws_vpcs.this.ids) == 1 ? data.aws_vpcs.this.ids[0] : fail(format(
    "Expected exactly one VPC tagged Project=%s Env=%s Component=network, found %d. Apply 10-network first.",
    var.project,
    var.env,
    length(data.aws_vpcs.this.ids),
  ))
}

data "aws_vpc" "this" {
  id = local.vpc_id

  depends_on = [data.aws_vpcs.this]
}

# Private subnets for the cluster. Public subnets are deliberately not consumed
# here: nothing in 30-cluster should be reachable from the internet, and not
# listing them makes an accidental public-subnet attachment a visible omission
# rather than a silent default.
#
# aws_subnets only returns ids and tags, so it is used purely as the filter and
# then expanded into per-id aws_subnet reads to get the CIDR and AZ.
data "aws_subnets" "private" {
  filter {
    name   = "tag:Project"
    values = [var.project]
  }

  filter {
    name   = "tag:Env"
    values = [var.env]
  }

  filter {
    name   = "tag:ManagedBy"
    values = ["terraform"]
  }

  filter {
    name   = "tag:Component"
    values = ["network"]
  }

  filter {
    name   = "tag:Tier"
    values = ["private"]
  }
}

data "aws_subnet" "private" {
  for_each = toset(data.aws_subnets.private.ids)

  id = each.value
}

locals {
  # Sorted by AZ so subnet_ids and subnet_cidrs stay aligned. The EC2 API returns
  # subnets in an arbitrary order, and pairing index 0 of one list with index 0
  # of another without a shared sort key would put the control plane's fixed IP
  # in a different AZ than the CIDR it was derived from.
  #
  # sort() takes no key argument, so the ordering is done with a comprehension:
  # the AZ names sorted lexicographically, then a lookup per AZ. Sorting map keys
  # is lexicographic, which is exactly what is wanted here.
  subnet_az_order = sort([for s in data.aws_subnet.private : s.availability_zone])

  subnets_by_az = {
    for s in data.aws_subnet.private : s.availability_zone => {
      id             = s.id
      cidr           = s.cidr_block
      az             = s.availability_zone
      az_id          = s.availability_zone_id
      default_for_az = s.default_for_az
    }
  }

  private_subnets = [for az in local.subnet_az_order : local.subnets_by_az[az]]

  private_subnet_ids   = [for s in local.private_subnets : s.id]
  private_subnet_cidrs = [for s in local.private_subnets : s.cidr]
}

check "private_subnets_found" {
  assert {
    condition     = length(local.private_subnet_ids) >= 2
    error_message = "Found ${length(local.private_subnet_ids)} private subnet(s). The worker ASG spreads across AZs and needs at least two for a control plane in one and workers in another to actually provide AZ failure tolerance."
  }
}

# Security groups created by 20-security, resolved by their Name tag. The
# component tag is "security" on all three groups, so Name is the discriminator.
data "aws_security_group" "control_plane" {
  filter {
    name   = "tag:Project"
    values = [var.project]
  }

  filter {
    name   = "tag:Env"
    values = [var.env]
  }

  filter {
    name   = "tag:Component"
    values = ["security"]
  }

  filter {
    name   = "tag:Name"
    values = ["${var.project}-${var.env}-control-plane"]
  }
}

data "aws_security_group" "workers" {
  filter {
    name   = "tag:Project"
    values = [var.project]
  }

  filter {
    name   = "tag:Env"
    values = [var.env]
  }

  filter {
    name   = "tag:Component"
    values = ["security"]
  }

  filter {
    name   = "tag:Name"
    values = ["${var.project}-${var.env}-workers"]
  }
}

locals {
  # A filter that matched nothing yields an empty id rather than an error, and a
  # security group id of "" fails deep inside an instance launch with an opaque
  # message. Failing here names the missing group.
  control_plane_sg_id = one(data.aws_security_group.control_plane[*].id) != null ? one(data.aws_security_group.control_plane[*].id) : fail(
    "Security group ${var.project}-${var.env}-control-plane not found. Apply 20-security first."
  )

  workers_sg_id = one(data.aws_security_group.workers[*].id) != null ? one(data.aws_security_group.workers[*].id) : fail(
    "Security group ${var.project}-${var.env}-workers not found. Apply 20-security first."
  )
}

# KMS keys created by 20-security. Resolved by alias rather than by key id: the
# alias is stable across key rotation, while a key id changes every time a key
# is replaced, which would churn the plan and silently re-point node encryption.
# The "kms-" infix is the naming module's component name, not "ebs"/"ssm".
data "aws_kms_alias" "ebs" {
  name = "alias/${var.project}-${var.env}-kms-ebs"
}

data "aws_kms_alias" "ssm" {
  name = "alias/${var.project}-${var.env}-kms-ssm"
}

# Instance profile for the nodes. Resolved by name, since IAM instance profiles
# are not taggable in a way that distinguishes them here.
data "aws_iam_instance_profile" "node" {
  name = "${var.project}-${var.env}-node-profile"
}

# ---------------------------------------------------------------------------
# Cluster layer
# ---------------------------------------------------------------------------
module "cluster" {
  source = "../../../modules/cluster"

  project     = var.project
  env         = var.env
  layer       = var.layer
  owner       = var.owner
  cost_center = var.cost_center

  aws_region    = var.aws_region
  standard_tags = module.foundation.standard_tags
  extra_tags    = var.extra_tags

  # AMI. Canonical has not published the /aws/service/canonical/... parameters
  # for 24.04 arm64 in ap-south-1, so the default is empty and the module falls
  # back to a DescribeImages lookup that tracks Ubuntu's point releases.
  ami_ssm_parameter = var.ami_ssm_parameter
  ami_id_override   = var.ami_id_override

  vpc_id   = local.vpc_id
  vpc_cidr = data.aws_vpc.this.cidr_block

  private_subnet_ids   = local.private_subnet_ids
  private_subnet_cidrs = local.private_subnet_cidrs

  # .10 in the first private subnet: the first user-assigned address, per AWS
  # convention, and outside the range 20-security's own NAT instance reserves.
  control_plane_fixed_ip_offset = var.control_plane_fixed_ip_offset

  control_plane_security_group_id = local.control_plane_sg_id
  workers_security_group_id       = local.workers_sg_id

  node_instance_profile_name = data.aws_iam_instance_profile.node.name
  ebs_kms_key_arn            = data.aws_kms_alias.ebs.target_key_arn

  # Matches the prefix 20-security grants the node role read/write on.
  ssm_path_prefix = "/${var.project}/${var.env}/k8s"

  kubernetes_version = var.kubernetes_version
  pod_cidr           = var.pod_cidr
  service_cidr       = var.service_cidr
  cluster_name       = var.cluster_name

  control_plane_instance_type    = var.control_plane_instance_type
  control_plane_root_volume_size = var.control_plane_root_volume_size

  worker_instance_types   = var.worker_instance_types
  worker_min_size         = var.worker_min_size
  compute_enabled         = var.compute_enabled
  worker_max_size         = var.worker_max_size
  worker_root_volume_size = var.worker_root_volume_size

  enable_spot_workers        = var.enable_spot_workers
  worker_spot_instance_types = var.worker_spot_instance_types

  # Empty until 40-edge creates the target group. A data source on the target
  # group here would fail the plan today; 40-edge runs after 30-cluster, so
  # whichever direction the reference goes, one of the two layers would need a
  # -target. Passing the ARNs in from tfvars keeps the dependency explicit and
  # optional.
  alb_target_group_arns = var.alb_target_group_arns

  etcd_backup_bucket_name = var.etcd_backup_bucket_name

  worker_pool_tags = var.worker_pool_tags
}

# The bucket name is asserted rather than derived, because 20-security already
# grants the node role access to a hardcoded name. If the two disagree the node
# would boot, fail its snapshot upload, and only say so in a timer log.
check "etcd_bucket_name" {
  assert {
    condition     = var.etcd_backup_bucket_name == format("%s-%s-etcd-backups", var.project, var.env)
    error_message = "etcd_backup_bucket_name must be <project>-<env>-etcd-backups to match the S3 grant in 20-security."
  }
}
