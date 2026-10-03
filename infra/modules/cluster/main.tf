# ---------------------------------------------------------------------------
# kubeadm cluster (Phase 4)
# ---------------------------------------------------------------------------
# One control plane as a plain aws_instance, workers as an ASG behind a launch
# template. Both roles boot from the Ubuntu 24.04 arm64 AMI and build their
# kubeadm configuration from the templates in templates/.
#
# Design notes that are easy to get wrong, so they are recorded here:
#
# 1. The control plane gets its OWN ENI with a fixed private IP rather than
#    using the instance's primary ENI. kubeadm writes controlPlaneEndpoint into
#    every node's kubeconfig and into the join command. If that endpoint were
#    the instance's primary ENI, replacing the control plane would change the IP
#    and every worker would have to be rebuilt too. A separate ENI with a
#    reserved address survives instance replacement, so controlPlaneEndpoint
#    stays stable across a control-plane rebuild.
#
# 2. Nodes have no public IP and no key pair. The only access path is SSM
#    Session Manager, via the instance profile created in 20-security. The
#    control plane has no launch template, only the workers do: aws_instance
#    cannot combine launch_template with an explicit network_interface, and the
#    dedicated ENI is the requirement.
#
# 3. IMDSv2 is required (http_tokens = "required"). IMDSv1 is a credential theft
#    risk on any host that can run untrusted code, and Kubernetes nodes run
#    third-party workloads.
#
# 4. The root volume is encrypted with the EBS KMS key from 20-security, so the
#    node disk (and anything kubeadm writes to it, including the admin
#    kubeconfig) is encrypted at rest under a customer-managed key.
#
# 5. Workers read the join command from SSM Parameter Store. The control plane
#    regenerates it on a timer because kubeadm's default token TTL is 15
#    minutes, which is shorter than the time it takes to notice a bad config
#    and re-apply.
#
# 6. The pod and service CIDRs must not overlap the VPC CIDR or each other. The
#    module asserts all three relationships; a silent overlap produces a cluster
#    that comes up but has no pod networking.

locals {
  name_prefix = "${var.project}-${var.env}"

  # Named resources, so every name comes from the naming module rather than being
  # hand-assembled at each call site.
  #
  # The map KEY is only the lookup handle (module.naming["..."]); the VALUE is the
  # name component handed to the naming module.
  naming_resources = {
    control_plane_eni  = "cp-eni"
    control_plane      = "cp"
    worker_lt          = "worker-lt"
    worker_asg         = "worker-asg"
    etcd_backup_bucket = "etcd-backups"
  }
}

module "naming" {
  source = "../naming"

  for_each = local.naming_resources

  name        = each.value
  project     = var.project
  env         = var.env
  layer       = var.layer
  owner       = var.owner
  cost_center = var.cost_center
  component   = "cluster"
}

locals {
  # The naming module's own tag set, with extra_tags layered on top.
  #
  # Every resource in this module takes its tags from here rather than from
  # module.naming[...].tags directly. The environment roots pass extra_tags all
  # the way in, so anything that reads the naming tags without also merging this
  # would accept that input and then quietly not apply it.
  resource_tags = {
    for key, naming in module.naming : key => merge(naming.tags, var.extra_tags)
  }
}
