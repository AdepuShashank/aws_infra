# ---------------------------------------------------------------------------
# Control plane
# ---------------------------------------------------------------------------
# A single aws_instance, not an ASG. The spec asks for exactly one control
# plane, and a control plane that is automatically replaced is a control plane
# that can lose quorum while you are trying to fix it.
#
# The dedicated ENI is the important part. kubeadm bakes controlPlaneEndpoint
# into every worker kubeconfig and into the join command. Pointing that at the
# instance's primary ENI means the endpoint changes every time the instance is
# replaced, and every worker has to be replaced with it. A separate ENI with a
# reserved private IP survives instance replacement, so the endpoint is stable.
#
# No launch template here, unlike the workers. A launch template cannot be
# combined with an explicit network_interface on aws_instance, and the dedicated
# ENI is the requirement. Everything else that a launch template would carry
# (AMI, type, root volume, IMDSv2, CloudWatch) is set directly below.

locals {
  # The reserved address for the control plane, taken from the first private
  # subnet. cidrhost with the /32 form gives a single address.
  control_plane_ip = cidrhost(var.private_subnet_cidrs[0], var.control_plane_fixed_ip_offset)

  control_plane_endpoint = "${local.control_plane_ip}:${var.api_server_port}"

  ssm_join_command    = "${var.ssm_path_prefix}/join-command"
  ssm_kubeconfig      = "${var.ssm_path_prefix}/admin-kubeconfig"
  ssm_ca_cert_hash    = "${var.ssm_path_prefix}/kubeadm-ca-cert-hash"
  ssm_bootstrap_state = "${var.ssm_path_prefix}/bootstrap-output"

  # Why templates/control-plane.sh.tftpl normalises kubeadm's token output instead
  # of taking two whitespace fields.
  #
  # kubeadm 1.36 prints `token create` as a SINGLE field, "<id>.<secret>" - stdout
  # is exactly that one string and stderr is empty (verified on a 1.36.5 control
  # plane). Older releases printed "<id> <secret> <expiry>". Parsing it as two
  # fields therefore yields an empty secret.
  #
  # The empty secret is the quiet failure this cost a day of debugging. The
  # publisher's own guard caught it and logged "kubeadm token create failed" on
  # every timer run, so nothing bad was published - but a join command with a bare
  # "--token" had already been written to SSM by an earlier run and stayed there,
  # because the guard's job was to refuse to overwrite it with something worse.
  # Every worker that booted after that read the stale command, failed to parse a
  # token out of it, exited non-zero, and never joined.
  #
  # The template therefore accepts both shapes and emits the id.secret form that
  # `kubeadm join --token` takes, keeping the bare id for revocation. The worker
  # half waits for a fully parseable command rather than aborting on the first
  # unparseable one, because an ASG that replaces an instance over a transient
  # parameter read just relaunches into the same race.

  kubeadm_config = {
    cluster_name           = var.cluster_name
    kubernetes_version     = var.kubernetes_version
    control_plane_endpoint = local.control_plane_endpoint
    control_plane_ip       = local.control_plane_ip
    api_server_port        = var.api_server_port
    pod_cidr               = var.pod_cidr
    service_cidr           = var.service_cidr
    # Rendered here rather than in the template: a Terraform list renders as
    # ["a" "b"], which bash would iterate as two literal words containing
    # brackets and quotes.
    cert_sans_yaml = join("\n", [
      for san in concat([local.control_plane_ip, "127.0.0.1", "localhost"], var.apiserver_cert_sans) :
      "    - ${san}"
    ])
    ssm_join_command    = local.ssm_join_command
    ssm_kubeconfig      = local.ssm_kubeconfig
    ssm_ca_cert_hash    = local.ssm_ca_cert_hash
    ssm_bootstrap_state = local.ssm_bootstrap_state
    region              = var.aws_region
    etcd_bucket         = var.etcd_backup_bucket_name
    snapshot_hours      = var.etcd_snapshot_interval_hours
  }

  # Shared cloud-init preamble. Kept in one place so the control plane and the
  # workers cannot drift on anything as basic as swap or sysctls.
  #
  # kubernetes_minor is precomputed here because "${kubernetes_version%.*}" is a
  # bash parameter expansion, and templatefile would try to evaluate it as a
  # Terraform expression.
  common_user_data = templatefile("${path.module}/templates/node-common.sh.tftpl", {
    kubernetes_version     = var.kubernetes_version
    kubernetes_minor       = "${join(".", slice(split(".", var.kubernetes_version), 0, 2))}"
    kubernetes_pkg_version = "${var.kubernetes_version}-1.1"
    containerd_repo_ubuntu = var.containerd_repo_ubuntu
    containerd_version_pin = var.containerd_version_pin
    ssm_path_prefix        = var.ssm_path_prefix
  })

  # Held unencoded here so user-data-guard.tf can measure it against EC2's limit.
  # Encoding happens at each use site.
  control_plane_user_data = templatefile("${path.module}/templates/control-plane.sh.tftpl", merge(local.kubeadm_config, {
    common = local.common_user_data
  }))
}

resource "aws_network_interface" "control_plane" {
  subnet_id = var.private_subnet_ids[0]

  # private_ips (the list) and NOT private_ip (the scalar).
  #
  # In provider v6 aws_network_interface still accepts private_ip and reports it
  # as optional+computed, but AWS never receives it: the ENI comes up on a
  # random address in the subnet. Verified against v6.67.0 by requesting
  # 10.10.10.10/.50/.77 and getting back 10.10.10.55/.184/10.10.10.246, while
  # the same subnet and security group through the raw API returns the address
  # asked for. The silent nature of this is what makes it expensive: Terraform
  # records whatever AWS assigned, so there is no drift error and no failed
  # apply, just a control plane whose advertised endpoint is not its own address
  # and a kubeadm that cannot come up.
  private_ips = [local.control_plane_ip]

  security_groups = [var.control_plane_security_group_id]

  description = "Fixed-IP ENI for the ${local.name_prefix} control plane. Holds the kubeadm controlPlaneEndpoint."

  tags = merge(local.resource_tags["control_plane_eni"], {
    Name = module.naming["control_plane_eni"].full_name
    Role = "control-plane"
  })
}

resource "aws_instance" "control_plane" {
  ami                  = local.ami_id
  instance_type        = var.control_plane_instance_type
  iam_instance_profile = var.node_instance_profile_name

  # The dedicated ENI becomes the primary interface. subnet_id,
  # associate_public_ip_address and vpc_security_group_ids are all absent because
  # they cannot be combined with network_interface. The ENI already places the
  # instance in a private subnet and already has the control-plane security group
  # attached, so repeating either here is not merely redundant, it is rejected.
  network_interface {
    network_interface_id = aws_network_interface.control_plane.id
    device_index         = 0
  }

  # No Elastic IP: a public address on the control plane would expose the API
  # server to the internet. This instance is only reachable over the VPC.

  # No key_name. SSH is intentionally unavailable; SSM Session Manager is the
  # only access path, per the spec's "no bastion" decision.

  # user_data_base64 rather than user_data: the latter stores a base64 blob in
  # state and makes Terraform warn that it cannot verify it. This matches the
  # convention already used by the NAT instance in 10-network.
  user_data_base64 = base64encode(local.control_plane_user_data)

  # The control plane writes the join command and kubeconfig to SSM on boot, so
  # a change to the bootstrap script must replace the instance.
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  # Detailed monitoring: one-minute CloudWatch metrics. The default is off, and
  # without it a node that is up but wedged looks identical to a healthy one.
  monitoring = true

  root_block_device {
    volume_size           = var.control_plane_root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    kms_key_id            = var.ebs_kms_key_arn
    delete_on_termination = true
    tags                  = merge(local.resource_tags["control_plane"], { Name = "${module.naming["control_plane"].full_name}-root" })
  }

  tags = merge(local.resource_tags["control_plane"], {
    Name = module.naming["control_plane"].full_name
    Role = "control-plane"
  })

}

resource "aws_ec2_instance_state" "control_plane" {
  instance_id = aws_instance.control_plane.id
  state       = var.compute_enabled ? "running" : "stopped"
}
