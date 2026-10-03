# ---------------------------------------------------------------------------
# fck-nat: NAT via a tiny Graviton instance instead of a NAT Gateway
# ---------------------------------------------------------------------------
# Why not the terraform-aws-modules/vpc nat-instance submodule?
#   nat-instance is not published in the v6 submodule list, and the v5-era
#   implementation routes with aws_route.instance_id. AWS provider 6 removed
#   `instance_id` as a writable argument on aws_route (it is now read-only), so
#   the only legal route target for an EC2 NAT box is network_interface_id.
#
# Why not an Auto Scaling Group?
#   A VPC route can only target a resource whose id Terraform knows at apply
#   time. With an ASG the ENI id is only knowable by reading live EC2 after the
#   instance has booted, which races: the ASG resource returns as soon as the
#   group is created, before any instance has an ENI. That makes the route
#   creation either flaky or dependent on a second apply.
#
#   A single aws_instance exposes primary_network_interface_id as a computed
#   attribute, so the route can reference it directly and Terraform orders the
#   graph correctly on the first apply. Single-apply determinism matters more
#   here than ASG-driven self-healing for a throwaway, cost-capped portfolio
#   environment. If the box dies, re-apply to replace it; there is no NAT
#   Gateway SLA being given up.
#
# Trade-off that is accepted deliberately: this is a single point of failure
# AND the route pins one ENI. See the nat_spot_warning output.

data "aws_ssm_parameter" "nat_ami" {
  name = var.nat_ami_parameter
}

locals {
  nat_user_data = <<-EOT
    #!/usr/bin/env bash
    set -euo pipefail

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y iptables

    # IP forwarding is required for the NAT instance to route between subnets.
    cat > /etc/sysctl.d/99-nat-forwarding.conf <<'SYSCTL'
    net.ipv4.ip_forward = 1
    net.ipv4.conf.all.accept_redirects = 0
    net.ipv4.conf.default.accept_redirects = 0
    SYSCTL
    sysctl --system

    # Masquerade anything sourced from the private CIDR leaving via a non-local
    # interface. "! -o lo" keeps the rule interface-agnostic, which matters
    # because the ENI name differs between Nitro and legacy instances.
    # shellcheck disable=SC2016
    iptables -t nat -C POSTROUTING -s '${var.vpc_cidr}' ! -o lo -j MASQUERADE 2>/dev/null \
      || iptables -t nat -A POSTROUTING -s '${var.vpc_cidr}' ! -o lo -j MASQUERADE

    # iptables rules are lost on reboot, so re-apply them from a unit.
    cat > /etc/systemd/system/nat-snat.service <<'UNIT'
    [Unit]
    Description=SNAT masquerade for the private subnets
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/bin/sh -c 'iptables -t nat -C POSTROUTING -s VPC_CIDR ! -o lo -j MASQUERADE || iptables -t nat -A POSTROUTING -s VPC_CIDR ! -o lo -j MASQUERADE'
    ExecStop=/bin/sh -c 'iptables -t nat -D POSTROUTING -s VPC_CIDR ! -o lo -j MASQUERADE || true'

    [Install]
    WantedBy=multi-user.target
    UNIT

    sed -i "s#VPC_CIDR#${var.vpc_cidr}#g" /etc/systemd/system/nat-snat.service

    systemctl daemon-reload
    systemctl enable --now nat-snat.service
  EOT
}

# Ingress from the VPC is required, and it is not about reaching the box.
#
# A masqueraded packet leaving a private node (10.10.10.10 -> 91.189.91.102)
# arrives on this instance's ENI, and security groups are evaluated on the way
# in, not against the masqueraded source. With no ingress rule at all the packet
# is dropped on arrival, long before POSTROUTING ever gets to rewrite the source,
# and the node sees a plain connection timeout rather than any iptables or
# routing error. Conntrack does cover the return path, but conntrack only exists
# once a connection has been permitted in the first place, so it cannot stand in
# for the forward path.
#
# Scoped to the VPC CIDR rather than 0.0.0.0/0 because nothing outside the VPC
# should ever address the box directly; the public IP is only ever used as the
# masquerade source.
resource "aws_security_group" "nat" {
  name        = "${var.name}-nat"
  description = "SNAT masquerade instance for the private subnets."
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "Forwarded traffic from the private subnets being masqueraded"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "All egress to the internet"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.name}-nat" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_instance" "nat" {
  ami                    = data.aws_ssm_parameter.nat_ami.value
  instance_type          = var.nat_instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.nat.id]
  source_dest_check      = false

  # Stop rather than terminate on shutdown so `terraform destroy` is the only
  # thing that removes the box; `terraform stop` keeps it recoverable.
  instance_initiated_shutdown_behavior = "stop"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  monitoring = true

  root_block_device {
    volume_size           = 8
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  # user_data_base64 rather than base64encode(user_data): the latter stores a
  # base64 blob in state and makes Terraform warn that it cannot verify it.
  user_data_base64 = base64encode(local.nat_user_data)

  tags = merge(local.tags, { Name = "${var.name}-nat" })

  lifecycle {
    # Reboot in place when the image, size or user data changes. An iptables or
    # sysctl change does not need a new ENI, and replacing it would tear the
    # route target out from under the private subnets.
    create_before_destroy = false

    ignore_changes = [
      # Rotating the AMI param is a deliberate operational action, not something
      # a plan should trigger on its own.
      ami,
    ]
  }
}

resource "aws_ec2_instance_state" "nat" {
  instance_id = aws_instance.nat.id
  state       = var.compute_enabled ? "running" : "stopped"
}

# ---------------------------------------------------------------------------
# Private default route -> NAT instance ENI
# ---------------------------------------------------------------------------
resource "aws_route" "private_default" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat.primary_network_interface_id
}