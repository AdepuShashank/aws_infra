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
# The control plane instance and its fixed IP are the only things this layer needs
# from 30-cluster. Resolved from 30-cluster's outputs through remote state rather
# than by tag, because an EC2 instance's tags are not guaranteed to survive every
# path that replaces one - and this layer attaches an SSM association to an
# instance id, so a wrong guess would configure the wrong node.
#
# The cluster details (name, pod CIDR) also come from remote state: they are
# kubeadm's inputs, and re-deriving them here would allow this layer to render a
# Calico IP pool that does not match what the control plane was initialised with.
# That mismatch is invisible at apply time and produces a cluster where every pod
# is stuck in ContainerCreating.

data "terraform_remote_state" "cluster" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "${var.env}/30-cluster/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  cluster = data.terraform_remote_state.cluster.outputs

  # A missing or empty output here would produce an association with no target
  # rather than an error, so it is turned into a named failure.
  control_plane_instance_id = try(local.cluster.control_plane_instance_id, null)
  control_plane_private_ip  = try(local.cluster.control_plane_endpoint, null)

  # The endpoint output is host:port; the SSM association wants the instance id,
  # and the private IP is only used as a tag.
  control_plane_ip = split(":", local.control_plane_private_ip)[0]

  cluster_name = try(local.cluster.cluster_name, "${var.project}-${var.env}")
  pod_cidr     = try(local.cluster.pod_cidr, null)
}

check "cluster_state_available" {
  assert {
    condition     = local.control_plane_instance_id != null && local.pod_cidr != null
    error_message = "30-cluster outputs (control_plane_instance_id, pod_cidr) are missing. Apply 30-cluster before 50-platform."
  }
}

# ---------------------------------------------------------------------------
# Platform bootstrap
# ---------------------------------------------------------------------------
module "platform" {
  source = "../../../modules/platform-bootstrap"

  project     = var.project
  env         = var.env
  layer       = var.layer
  owner       = var.owner
  cost_center = var.cost_center

  aws_region = var.aws_region
  extra_tags = var.extra_tags

  # Must match the prefix 20-security grants the node role write access to and that
  # 30-cluster publishes into. If these drift, the bootstrap script writes
  # parameters the nodes cannot read back and the run fails at the last step.
  ssm_path_prefix = "/${var.project}/${var.env}/k8s"

  ssm_kms_key_arn = data.aws_kms_alias.ssm.target_key_arn

  control_plane_instance_id = local.control_plane_instance_id
  control_plane_private_ip  = local.control_plane_ip

  cluster_name = local.cluster_name
  pod_cidr     = local.pod_cidr

  calico_version       = var.calico_version
  helm_version         = var.helm_version
  helm_sha256          = var.helm_sha256
  argocd_chart_version = var.argocd_chart_version

  gitops_repo_url        = var.gitops_repo_url
  gitops_ssh_host        = var.gitops_ssh_host
  gitops_repo_path       = var.gitops_repo_path
  gitops_target_revision = var.gitops_target_revision

  association_schedule = var.association_schedule

  depends_on = [module.foundation]
}

data "aws_kms_alias" "ssm" {
  name = "alias/${var.project}-${var.env}-kms-ssm"
}
