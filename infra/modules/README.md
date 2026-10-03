# Infrastructure modules

Every module is self-contained, accepts only typed/validated variables, applies the standard tag set,
and exposes documented outputs. No module may hardcode an account id, region or CIDR.

## Shared helpers

| Module | Purpose | Built in |
|---|---|---|
| [`foundation`](foundation) | Provider + region + standard tags + validated common variables. Instantiated once per layer root. | Phase 0 |
| [`naming`](naming) | Pure-computation helper that produces `project-env-name[-suffix]` and the standard tag map. Instantiated inside resource modules. | Phase 0 |

## Resource modules

| Module | Purpose | Built in |
|---|---|---|
| `network` | VPC, 2 public + 2 private subnets, route tables, S3 gateway endpoint, fck-nat, optional flow logs | Phase 2 |

Implementation note: fck-nat is a single `aws_instance`, not the upstream
`nat-instance` submodule. AWS provider 6 removed `instance_id` as a writable
target on `aws_route`, and an ASG cannot expose its instances' ENI ids without
racing instance boot. See [`docs/adr/0001-fck-nat.md`](../../docs/adr/0001-fck-nat.md).

| `cluster` | Control-plane EC2 (fixed-ENI / fixed private IP), worker ASG, launch templates, cloud-init | Phase 4 (built) |
| `edge` | ALB, listeners, target group, optional Route 53 / ACM | Phase 5 (built) |
| `platform-bootstrap` | SSM-driven install of Calico + Argo CD + root app-of-apps | Phase 6 (built) |
| `data-backups` | S3 buckets (etcd, postgres), lifecycle rules, DLM snapshot policy | Phase 7 |
| `observability` | CloudWatch log groups, alarms, SNS topic | Phase 7 |
| `scheduler` | EventBridge Scheduler stop/start schedules (qa) | Phase 7 |

Implementation notes:

- **fck-nat** is a single `aws_instance`, not the upstream `nat-instance`
  submodule. AWS provider 6 removed `instance_id` as a writable target on
  `aws_route`, and an ASG cannot expose its instances' ENI ids without racing
  instance boot. See [`docs/adr/0001-fck-nat.md`](../../docs/adr/0001-fck-nat.md).
- **security** uses standalone `aws_vpc_security_group_ingress_rule` /
  `_egress_rule` resources rather than inline blocks, because the ALB and worker
  groups reference each other and inline blocks would be a dependency cycle. See
  [`docs/security-baseline.md`](../../docs/security-baseline.md).

Module directories exist from Phase 0 so the repository skeleton is stable, but
they stay empty until their phase is implemented.

Module directories exist from Phase 0 so the repository skeleton is stable, but they stay empty
until their phase is implemented — see [`CHECKPOINT.md`](../../CHECKPOINT.md).

## Conventions

- Names: `project-env-name[-suffix]`, produced by the `naming` module. Never hand-rolled.
- Tags: `Name`, `Project`, `Env`, `Layer`, `Owner`, `ManagedBy=terraform`, `CostCenter`.
  Applied via `provider.aws.default_tags`; resources that ignore `default_tags`
  (autoscaling groups, launch templates, some route-table records) are tagged explicitly.
- Every variable has a `description`, a `type`, and a `validation` block where it can be checked.
- Every output has a `description`.
- `terraform fmt`, `terraform validate`, `tflint` and `checkov` must pass. See `.pre-commit-config.yaml`.

## Variable files

Variables are split across two files per layer so plans are warning-free.
Terraform warns about any value in a `-var-file` that the root module does not
declare, so a single shared file covering all six layers produces a dozen
"value for undeclared variable" warnings per plan.

| File | Contents |
|---|---|
| `infra/envs/<env>/common.tfvars` | Only what every layer root declares, because every layer root calls `modules/foundation`: `project`, `env`, `owner`, `cost_center`, `aws_region`, `extra_tags`, `alb_allowed_cidrs`, `domain_name`. |
| `infra/envs/<env>/<layer>/<env>.tfvars` | Everything that layer alone owns, for example `vpc_cidr` in `10-network/prod.tfvars`. |

Plan from a layer root, passing both files:

```powershell
terraform plan -input=false "-var-file=..\common.tfvars" "-var-file=prod.tfvars"
```

Later layers in the order Terraform reads the files, so per-layer values win:

```powershell
terraform plan -input=false `
  "-var-file=..\common.tfvars" `
  "-var-file=prod.tfvars"
```

Quote the `-var-file=` arguments in PowerShell. Unquoted, PowerShell hands
Terraform a bare `=..\common.tfvars` positional argument and it fails with
`Too many command line arguments`.

If a future layer needs to change a `common.tfvars` value for itself only, copy
it into that layer's file rather than editing the shared one.