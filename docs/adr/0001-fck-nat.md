# ADR 0001: NAT via a single Graviton instance, not a NAT Gateway or an ASG

- Status: accepted
- Date: 2026-10-02
- Affects: `infra/modules/network/fck-nat.tf`, `infra/envs/*/10-network`

## Context

Private subnets need outbound internet access for: image and package pulls,
SSM Session Manager, etcd snapshots to S3, and Argo CD repository sync. A NAT
Gateway is the default answer and was explicitly ruled out, because in
`ap-south-1` a NAT Gateway costs roughly USD 32/month plus data processing,
which on its own would dominate the entire environment budget.

The upstream `terraform-aws-modules/vpc/aws` `nat-instance` submodule is the
usual home for this pattern, but two things ruled it out.

### 1. `nat-instance` is not published for v6

The module's latest release is `6.7.3`, and the published submodule list for
that release contains `vpc-endpoints`, `flow-log`, and others, but no
`nat-instance`. The v5-era submodule routed with `aws_route.instance_id`, which
is exactly the mechanism that no longer works (below). Adopting a pinned v5
module would also mean pinning the whole VPC module to v5 and losing the v6
provider integration.

### 2. AWS provider 6 made `instance_id` read-only on `aws_route`

A VPC route can only target a resource id that Terraform knows at apply time.
In provider 6 the writable target list for `aws_route` is:

`carrier_gateway_id`, `core_network_arn`, `egress_only_gateway_id`, `gateway_id`,
`local_gateway_id`, `nat_gateway_id`, `network_interface_id`, `odb_network_arn`,
`transit_gateway_id`, `vpc_endpoint_id`, `vpc_peering_connection_id`

`instance_id` is present in the schema but is read-only, so
`instance_id = <ec2 instance>` is a hard error:

```
Error: Value for unconfigurable attribute
  Can't configure a value for "instance_id": its value will be decided
  automatically based on the result of applying this configuration.
```

The only legal target for an EC2 NAT box is therefore `network_interface_id`.

## Decision

Use a single `aws_instance` of type `t4g.nano` with `source_dest_check = false`,
and point the private route table's default route at that instance's
`primary_network_interface_id`.

### Why `aws_instance` and not an Auto Scaling Group

This was the first implementation, and it was rejected on correctness grounds.

An ASG does not expose the ENI id of its instances. The only way to learn it is
to read live EC2 state, for example `aws_network_interfaces` filtered by a tag
that the ASG applies. That read races against instance boot:

- The `aws_autoscaling_group` resource returns as soon as the group is created.
  Instances are `Pending` at that point and have no ENI.
- A data source filtered on the ASG tag therefore returns an empty set, and
  `network_interface_id` resolves to `null`, which fails the route create.

Making that work reliably would require either a second `terraform apply` or a
sleep-and-retry wrapper, both of which are unacceptable for an environment whose
stated goal is fast, repeatable teardown and rebuild.

`aws_instance` exposes `primary_network_interface_id` as a computed attribute.
Terraform's dependency graph orders the route after the instance on the first
apply, with no race and no retry logic.

### Why the ASG was still the wrong shape anyway

The ASG only ever ran `min_size = max_size = desired_capacity = 1`, because this
module builds a single private route table and a route table can carry only one
`0.0.0.0/0`. An ASG wrapping a single instance buys self-healing replacement,
but it cannot help when the route target is the thing that needs updating: a
replacement instance gets a new ENI, and the route still points at the old one.
So the ASG would not actually have delivered self-healing, only an extra moving
part.

`single_nat_instance` is retained as a variable pinned to `true` by validation,
so the constraint is visible in the interface rather than implied.

## Consequences

Accepted:

- **Single point of failure.** If the NAT instance is replaced outside
  Terraform, the private default route points at a stale ENI and private egress
  stops until the next `terraform apply`. The `nat_spot_warning` output states
  this in every plan.
- **No ASG-driven recovery.** A crashed instance stays crashed until re-applied.
  `instance_initiated_shutdown_behavior = "stop"` is set so an
  `aws:StopInstances` call does not destroy the box, making recovery a
  `StartInstances` away.
- **No multi-AZ NAT.** One `t4g.nano` serves every private subnet. Supporting
  one NAT per AZ requires a private route table per AZ, which is a real change
  to the module and was not worth it for an environment with two workers.

Rejected alternatives:

- **NAT Gateway.** Roughly USD 32/month plus per-GB processing. This is the
  single biggest line item the cost budget is trying to avoid.
- **Interface VPC endpoints for everything.** Each is about USD 7.30/month in
  this region, and the set needed to cover registry, SSM, and STS traffic would
  cost more than the NAT instance it replaces. They remain available per-service
  via `interface_endpoint_services`, and the S3 gateway endpoint (free) is on by
  default.
- **`terraform-aws-modules/vpc/aws` v5.** Would have to pin the whole VPC module
  below v6 for a submodule that no longer has a v6 equivalent.

## Operational note

The iptables masquerade rule and the IP forwarding sysctl are applied by
`user_data` on first boot and re-applied on boot by the `nat-snat.service`
unit, because iptables rules do not survive a reboot. If the instance is
replaced, `terraform apply` reinstalls `user_data`, so the box self-configures.