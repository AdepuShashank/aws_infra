# Account capacity: the 8-vCPU limit

Everything in this repository is sized against a hard limit: this AWS account has
an **on-demand vCPU quota of 8** for the standard (non-burstable) instance family
in `ap-south-1`. Nothing in the account can raise it without a support request, so
it is a design constraint rather than a temporary condition.

## The number that matters: T4g vCPU counts

Every T4g size from `nano` up to `large` has **2 vCPUs**. This is the single fact
that changes every sizing decision here.

| Instance type | vCPU | Memory | Used for |
|---|---|---|---|
| `t4g.nano` | 2 | 0.5 GiB | fck-nat |
| `t4g.small` | 2 | 2 GiB | control plane |
| `t4g.medium` | 2 | 4 GiB | worker |

`Infrastructure.MD`'s sizing notes assume `t4g.nano` and `t4g.small` are 1 vCPU.
They are not. Assuming so makes the whole plan look like it fits when it does not,
and the mismatch only shows up as `VcpuLimitExceeded` on a scale-out, at which
point the ASG has already given up.

## Where the 8 go

| Component | vCPU | Running? |
|---|---|---|
| prod NAT (`t4g.nano`) | 2 | yes |
| prod control plane (`t4g.small`) | 2 | yes |
| prod worker × 1 (`t4g.medium`) | 2 | yes |
| **subtotal** | **6** | |
| prod worker × 2 (`t4g.medium`) | +2 | 8, at the limit |

So prod alone fits at **one worker**, and sits exactly on 8 at two.

## Why two workers is not viable

Landing exactly on the quota is not a stable place to be. EC2 enforces the limit
per launch, and the running total at the moment of the launch is not the same as
the steady state: a scale-out races its own instance coming up, and an instance
that is `pending` already counts. Observed on 2026-10-03:

- 09:57 - prod scaled 0 -> 2 workers. One worker launched, the second was rejected.
  Terraform waited the full 10-minute capacity timeout and failed the apply.
- 10:19 - a throwaway ASG using the same launch template reached 2 instances,
  total 10 vCPU, and succeeded.
- 10:32 - an identical group at 8 vCPU already running was rejected for a second
  instance with `VcpuLimitExceeded`.

Same limit, same instance types, three different outcomes. A worker count that is
sometimes 1 and sometimes 2 depending on timing is worse than a worker count that
is always 1, so `worker_min_size` is 1 and `worker_max_size` is 2 in prod.

## What is set where

| Layer | Setting | Value |
|---|---|---|
| `30-cluster` | `worker_min_size` | 1 (not the MD's 2) |
| `30-cluster` | `worker_max_size` | 2 (not the MD's 3) |
| `30-cluster` | `control_plane_instance_type` | `t4g.small` |
| `30-cluster` | `compute_enabled` | controls whether any of this runs |

`worker_max_size = 2` is documented but not exercised: reaching it puts prod on the
limit again. It is there so that scaling out is a deliberate act, not something
that happens on its own.

## qa cannot run alongside prod

qa's NAT plus control plane is another 4 vCPU. With prod at 6 that is exactly 10,
over the limit. So:

- qa stays `compute_enabled = false` while prod runs.
- Bringing qa up means prod's worker ASG at `worker_min_size = 1`, which leaves 2
  vCPU - enough for qa's NAT but not for qa's NAT *and* control plane.

The environments are genuinely mutually exclusive at this quota. That matches the
intent of the MD (qa is torn down most of the week) but it is a quota consequence,
not a choice, and it should not be described as one.

## Restoring the MD's defaults

| MD default | Needs |
|---|---|
| prod 2 workers, max 3 | on-demand vCPU quota of 16 |
| prod and qa running at once | on-demand vCPU quota of 24 |

Request the increase with AWS Support (Service Quotas -> Amazon EC2 -> Standard
instance vCPU limit), or use EC2 On-Demand Capacity Reservations / Savings Plans,
which raise the effective on-demand limit. Once the quota is 16, set
`worker_min_size = 2` and `worker_max_size = 3` in
`infra/envs/prod/30-cluster/prod.tfvars` and nothing else needs to change.

## How to check it

```powershell
aws ec2 describe-instance-types --region ap-south-1 --instance-types t4g.medium `
  --query 'InstanceTypes[0].VCpuInfo.DefaultVCpus'
```

`servicequotas:GetServiceQuota` is not granted to the operator user in this
account, so the limit itself cannot be read from the CLI - it is observed by
launching and reading the error text.
