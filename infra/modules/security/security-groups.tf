# ---------------------------------------------------------------------------
# Security groups
# ---------------------------------------------------------------------------
# Three groups, matching the spec:
#
#   alb            80/443 from allowed_cidrs only. Egress limited to the
#                  Traefik NodePorts on the workers group.
#   workers        NodePorts from the alb group. Node-to-node all protocols.
#   control-plane  node-to-node all protocols, plus the API server and kubelet
#                  ports from workers and control-plane only.
#
# Why node-to-node is "all protocols" rather than a narrow port list:
# Calico in VXLAN mode needs UDP 4789 between every pair of nodes, and kubelet
# needs TCP 10250. Both are dictated by the CNI, so pinning a fixed list here
# would silently break pod networking after a Calico upgrade. The rules are
# still scoped to the VPC CIDR, so nothing off-VPC can use them.
#
# Why rules are standalone resources rather than inline ingress/egress blocks:
# the ALB group and the workers group reference each other (the ALB egresses to
# the NodePorts, the workers allow those NodePorts from the ALB). Inline blocks
# on the security groups themselves would be a dependency cycle:
#
#   Cycle: aws_security_group.alb, aws_security_group.workers
#
# Separating the rules into aws_vpc_security_group_ingress_rule /
# _egress_rule resources breaks the cycle, because a rule depends on both groups
# while the groups themselves depend on neither.
#
# There is no rule for port 22 anywhere in this module. The `nodeports`
# variable has a validation that rejects 22. Operator access is SSM Session
# Manager only.

locals {
  nodeports = toset(var.nodeports)

  # for_each accepts only maps and sets of strings, but from_port/to_port need
  # numbers. Keying the set by the stringified port satisfies both: each.key is
  # a usable map key and each.value stays a number for the rule itself.
  nodeport_rules = { for p in local.nodeports : tostring(p) => p }
}

resource "aws_security_group" "alb" {
  name        = module.naming["alb"].full_name
  description = "Public load balancer. Only 80/443 from allowed_cidrs."
  vpc_id      = var.vpc_id

  # No inline blocks: every rule for this group lives below as a standalone
  # resource so the cross-group references do not cycle.

  tags = merge(module.naming["alb"].tags, { Name = module.naming["alb"].full_name })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "workers" {
  name        = module.naming["workers"].full_name
  description = "Kubernetes worker nodes. NodePorts from the ALB, node-to-node all protocols."
  vpc_id      = var.vpc_id

  tags = merge(module.naming["workers"].tags, { Name = module.naming["workers"].full_name })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "control_plane" {
  name        = module.naming["control-plane"].full_name
  description = "Control plane. API server from nodes only; no internet ingress."
  vpc_id      = var.vpc_id

  tags = merge(module.naming["control-plane"].tags, { Name = module.naming["control-plane"].full_name })

  lifecycle {
    create_before_destroy = true
  }
}

# ----------------------------------------------------------------- ALB rules ---

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each = toset(var.allowed_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "HTTP from allowed CIDRs"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each = toset(var.allowed_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from allowed CIDRs"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# Egress is pinned to the NodePorts on the workers group rather than 0.0.0.0/0,
# so a compromised ALB has no outbound path to anything else in the account.
resource "aws_vpc_security_group_egress_rule" "alb_nodeports" {
  for_each = local.nodeport_rules

  security_group_id            = aws_security_group.alb.id
  description                  = "Traefik NodePort to the worker nodes"
  referenced_security_group_id = aws_security_group.workers.id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
}

# -------------------------------------------------------------- worker rules ---

# Node-to-node: Calico VXLAN (UDP 4789), kubelet (TCP 10250), and the CNI's own
# control traffic. Scoped to the VPC so it is not reachable from the internet.
resource "aws_vpc_security_group_ingress_rule" "workers_node_to_node" {
  security_group_id = aws_security_group.workers.id
  description       = "Node-to-node (Calico VXLAN, kubelet, CNI)"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"
}

# Workload traffic from the load balancer, restricted to the declared
# NodePorts. A new workload port has to be added here deliberately.
resource "aws_vpc_security_group_ingress_rule" "workers_nodeports" {
  for_each = local.nodeport_rules

  security_group_id            = aws_security_group.workers.id
  description                  = "Traefik NodePort from the ALB"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
}

resource "aws_vpc_security_group_egress_rule" "workers_all" {
  security_group_id = aws_security_group.workers.id
  description       = "All egress (NAT instance, S3 gateway endpoint, internet via NAT)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ------------------------------------------------------ control plane rules ---

resource "aws_vpc_security_group_ingress_rule" "control_plane_node_to_node" {
  security_group_id = aws_security_group.control_plane.id
  description       = "Node-to-node (Calico VXLAN, kubelet, CNI)"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "control_plane_apiserver" {
  security_group_id            = aws_security_group.control_plane.id
  description                  = "Kubernetes API server from workers and control plane"
  referenced_security_group_id = aws_security_group.workers.id
  ip_protocol                  = "tcp"
  from_port                    = var.apiserver_port
  to_port                      = var.apiserver_port
}

# Self-reference: the API server must accept its own port, which is what makes
# `kubectl` work from a control-plane session.
resource "aws_vpc_security_group_ingress_rule" "control_plane_apiserver_self" {
  security_group_id            = aws_security_group.control_plane.id
  description                  = "Kubernetes API server from the control plane itself"
  referenced_security_group_id = aws_security_group.control_plane.id
  ip_protocol                  = "tcp"
  from_port                    = var.apiserver_port
  to_port                      = var.apiserver_port
}

resource "aws_vpc_security_group_ingress_rule" "control_plane_kubelet" {
  security_group_id            = aws_security_group.control_plane.id
  description                  = "Kubelet from workers (kubectl logs/exec/port-forward)"
  referenced_security_group_id = aws_security_group.workers.id
  ip_protocol                  = "tcp"
  from_port                    = var.kubelet_port
  to_port                      = var.kubelet_port
}

resource "aws_vpc_security_group_egress_rule" "control_plane_all" {
  security_group_id = aws_security_group.control_plane.id
  description       = "All egress (NAT instance, S3 gateway endpoint, internet via NAT)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
