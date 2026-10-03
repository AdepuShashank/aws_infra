# ---------------------------------------------------------------------------
# CIDR safety
# ---------------------------------------------------------------------------
# kubeadm does not validate that the pod and service CIDRs are disjoint from the
# VPC or from each other. If they overlap, the control plane comes up, kubelet
# starts, and pods get no connectivity: Calico's VXLAN routes point at addresses
# that resolve to the VPC router instead of to pod IPs. The symptom is a cluster
# that looks healthy in `kubectl get nodes` and cannot reach anything.
#
# Terraform has no cidrcontains, so overlap is tested the long way: each CIDR's
# network address is converted to an integer, its size is derived from the
# prefix length, and two ranges overlap when each starts before the other ends.
#
#   pod 10.200.0.0/16 inside service 10.96.0.0/12
#     pod_base >= service_base  and  pod_base < service_base + service_size

locals {
  cluster_cidrs = {
    vpc     = var.vpc_cidr
    pod     = var.pod_cidr
    service = var.service_cidr
  }

  # base: the network address as an integer.
  #   10.10.0.0 -> 10*256^3 + 10*256^2 + 0 + 0
  # size: how many addresses the block covers, 2^(32 - prefix).
  cidr_ranges = {
    for key, cidr in local.cluster_cidrs : key => {
      cidr = cidr
      base = sum([
        for octet_index, octet in split(".", cidrhost(cidr, 0)) :
        tonumber(octet) * pow(256, 3 - octet_index)
      ])
      size = pow(2, 32 - tonumber(split("/", cidr)[1]))
    }
  }

  # Every unordered pair of distinct ranges.
  cidr_pairs = [
    for pair in setproduct(keys(local.cidr_ranges), keys(local.cidr_ranges)) :
    "${pair[0]}|${pair[1]}"
    if pair[0] != pair[1]
  ]

  # Only the pairs that actually overlap, so the failure message can name them.
  overlapping_cidrs = [
    for pair in local.cidr_pairs : pair
    if local.cidr_ranges[split("|", pair)[0]].base < local.cidr_ranges[split("|", pair)[1]].base + local.cidr_ranges[split("|", pair)[1]].size
    &&
    local.cidr_ranges[split("|", pair)[1]].base < local.cidr_ranges[split("|", pair)[0]].base + local.cidr_ranges[split("|", pair)[0]].size
  ]
}

check "cidrs_are_disjoint" {
  assert {
    condition     = length(local.overlapping_cidrs) == 0
    error_message = "Overlapping CIDRs: ${join(", ", local.overlapping_cidrs)}. Overlapping ranges produce a cluster that boots but has no pod or service networking. vpc=${var.vpc_cidr} pod=${var.pod_cidr} service=${var.service_cidr}"
  }
}

# The fixed control-plane address must fall inside the first private subnet.
#
# cidrhost silently clamps an out-of-range hostnum to the block, so without this
# check a too-large offset yields a valid-looking IP inside a subnet the ENI is
# not attached to, and AWS rejects the ENI with a message that never mentions the
# offset.
locals {
  first_subnet_range = {
    base = sum([
      for octet_index, octet in split(".", cidrhost(var.private_subnet_cidrs[0], 0)) :
      tonumber(octet) * pow(256, 3 - octet_index)
    ])
    size = pow(2, 32 - tonumber(split("/", var.private_subnet_cidrs[0])[1]))
  }

  control_plane_ip_num = sum([
    for octet_index, octet in split(".", cidrhost(var.private_subnet_cidrs[0], var.control_plane_fixed_ip_offset)) :
    tonumber(octet) * pow(256, 3 - octet_index)
  ])
}

check "control_plane_ip_in_first_subnet" {
  assert {
    condition = (
      local.control_plane_ip_num >= local.first_subnet_range.base &&
      local.control_plane_ip_num < local.first_subnet_range.base + local.first_subnet_range.size
    )
    error_message = "control_plane_fixed_ip_offset ${var.control_plane_fixed_ip_offset} resolves to ${cidrhost(var.private_subnet_cidrs[0], var.control_plane_fixed_ip_offset)}, which is outside ${var.private_subnet_cidrs[0]}."
  }
}
