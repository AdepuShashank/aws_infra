# 0002 - Worker ASG on-demand allocation and the 8-vCPU quota

**Status:** accepted, 2026-10-03
**Relates to:** `docs/quota.md`, `infra/modules/cluster/workers.tf`

## Context

Bringing the prod cluster up from `compute_enabled = false` meant scaling a worker
ASG from 0 to 2. It launched one instance and then stopped. Terraform sat on the
capacity check for the full 10-minute provider timeout and failed the apply with:

```
Error: waiting for Auto Scaling Group (...) capacity satisfied: timeout
while waiting for state to become 'ok' (last state: 'want exactly 2 healthy
instance(s) in Auto Scaling Group, have 100', timeout: 10m0s)
```

`have 100` is one instance out of one wanted, so the group was half-built and
reported no failed activity. Recreating the ASG reproduced it. Raising
`desired_capacity` produced no activity at all. Nothing in the group's activity
log, and nothing in Terraform, pointed at a cause.

## What was actually wrong

Two separate problems.

### 1. `on_demand_allocation_strategy = "prioritized"`

`prioritized` requires every launch template override to carry a `priority`, and
provider v6's `override` block accepts only `instance_type` and
`weighted_capacity`. The priority cannot be expressed.

AWS accepts the policy, then cannot allocate on-demand capacity from it. A probe
group with `prioritized` launched **zero** instances for a desired capacity of 2.
The same launch template in a group with no mixed instances policy launched 2
immediately.

`lowest-price` is the correct value, and note the hyphen: the camelCase
`lowestPrice` that older examples show is rejected outright with
`OnDemandAllocationStrategy is not valid. Valid options are: [prioritized,
lowest-price]`.

### 2. The account is on the quota, and the quota is enforced unevenly

With `prioritized` fixed, scale-outs were still intermittently refused. The
evidence, in order:

| Time | Group | Running total | Result |
|---|---|---|---|
| 09:57 | prod workers, desired 2 | 6 vCPU | 1 launched, 1 refused |
| 10:19 | probe, no mixed policy, desired 2 | 6 vCPU | both launched (total 10) |
| 10:32 | probe, `lowest-price`, desired 2 | 8 vCPU | 1 launched, 1 `VcpuLimitExceeded` |
| 10:33 | prod workers, desired 1 | 6 vCPU | converged |

The limit is 8. A total of exactly 8 is accepted sometimes and refused other
times, because the running total at the moment of the launch includes instances
still coming up. An ASG pinned to the limit therefore produces a group whose
worker count is a function of timing.

## Decision

1. `on_demand_allocation_strategy` is `"lowest-price"`, never `"prioritized"`,
   and the reason is recorded next to the setting so it is not "corrected" back.
2. `timeouts { update = "20m", delete = "20m" }` on the ASG. The provider default
   is 10 minutes and DescribeScalingActivities regularly returns its own
   `context deadline exceeded` while the group is scaling; a timeout there fails
   an apply whose group reached the capacity it was asked for, and then has to be
   re-applied just to record state.
3. Prod runs `worker_min_size = 1`, `worker_max_size = 2` instead of the MD's 2/3,
   so the steady state is 6 of 8 with the scale-out to 2 being a deliberate act.

## Consequences

- Prod and qa cannot run at the same time at this quota. See `docs/quota.md`.
- Restoring the MD's sizing needs a quota increase, not a code change.
- The two-node AZ spread the ASG asks for is still expressed; with one worker it is
  a preference that costs nothing rather than a guarantee.

## Alternatives rejected

**Request the quota increase first.** It is the right long-term answer and it was
not available - the work had to be unblocked now. The sizing changes are the
fallback that makes the build work at the current quota, and they are cheaper to
reverse than a waiting support ticket.

**Drop the worker ASG to a single `aws_instance`.** It would halve the launch
chance of a quota race and remove the refresh path, but a disposable worker that
cannot be replaced automatically is worse than a group that is sometimes one node
short. The instance-refresh path is also the thing that has to work before
anything else does.

**Keep 2/3 and let Terraform time out.** It fails loudly, which is honest, but it
makes every apply a gamble and leaves the cluster in a state where the node count
depends on whether the apply happened to run in a quiet moment.
