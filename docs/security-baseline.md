# Security baseline

Layer `20-security`. Applies after `10-network`; the VPC is resolved by tag
lookup (`Project`, `Env`, `ManagedBy`, `Component=network`) rather than
by re-declaring it.

## What is created

| Resource | Notes |
|---|---|
| `dpx-<env>-alb` | 80/443 from `alb_allowed_cidrs` only; egress pinned to the Traefik NodePorts on the workers group |
| `dpx-<env>-workers` | NodePorts from the ALB, node-to-node all protocols within the VPC CIDR |
| `dpx-<env>-control-plane` | API server 6443 and kubelet 10250 from workers and control-plane only |
| `dpx-<env>-node-role` / `-node-profile` | Instance profile for future cluster nodes |
| `alias/dpx-<env>-kms-ebs` | EBS volume encryption, annual rotation |
| `alias/dpx-<env>-kms-ssm` | SSM SecureString encryption, annual rotation |

## Notable decisions

- **No SSH anywhere.** Port 22 does not appear in any rule, and the
  `nodeports` variable has a validation that rejects it. Operator access is
  SSM Session Manager, backed by `AmazonSSMManagedInstanceCore`.
- **Rules are standalone resources.** The ALB and workers groups reference each
  other, so inline `ingress`/`egress` blocks on the groups themselves create
  a dependency cycle. `aws_vpc_security_group_ingress_rule` /
  `_egress_rule` resources break it.
- **Node-to-node is all protocols, scoped to the VPC CIDR.** Calico VXLAN
  (UDP 4789) and kubelet (TCP 10250) are dictated by the CNI; a fixed port list
  would break pod networking on a Calico upgrade.
- **ALB egress is not `0.0.0.0/0`.** It is limited to the workers group on the
  declared NodePorts, so a compromised ALB has no general outbound path.
- **Worker egress is unrestricted**, because pods need to reach the NAT
  instance, the S3 gateway endpoint, and the internet for image pulls. Tighten
  this only alongside egress proxies; it is the known loose edge.

## IAM managed policies

The node role attaches three AWS-managed policies:

- `AmazonSSMManagedInstanceCore`
- `service-role/AmazonEBSCSIDriverPolicy` — note the `service-role/` path.
  The similarly named `AmazonEBSCSIDriverPolicyV2` at the policy root is the
  EKS add-on variant and is not what a self-managed node wants.
- `CloudWatchAgentServerPolicy`

## Backup buckets

`20-security` grants the node role object access to
`dpx-<env>-etcd-backups` and `dpx-<env>-postgres-backups`, but does not
create them; `70-backups` owns those. A `check` block in the root asserts the
names match the pattern exactly, so the grant and the bucket cannot drift apart.