# Build status

Where the build actually is, as of **2026-10-04**. Phases 0-6 are applied in prod;
7 and 8 are written but not synced, because Argo CD still cannot fetch the
repository. The 60-ops layer, `scripts/`, and CI/CD are now built and plan clean.
Two things block the rest, both listed at the bottom.

## PAUSED FOR COST - resume here first

Compute is stopped. `compute_enabled = false` in
`infra/envs/prod/10-network/prod.tfvars` and `infra/envs/prod/30-cluster/prod.tfvars`,
both layers applied:

| Resource | State after pause |
|---|---|
| prod NAT (`i-040fbed3491c1a19c`) | **stopped in place** |
| prod control plane (`i-0b7d611942ed0a2c3`) | **stopped in place** |
| prod worker ASG | **scaled to 0**, worker instances terminated |
| qa NAT (`i-096700562d53aab75`) | already stopped |

Nothing was destroyed. The control plane's root volume survives, so etcd - and
therefore all cluster state - comes back with it. The worker ASG will launch a
fresh worker, which joins from the SSM-published token like any new node.

### To resume

```powershell
# 1. flip the flag back in both layers
#    infra\envs\prod\10-network\prod.tfvars  ->  compute_enabled = true
#    infra\envs\prod\30-cluster\prod.tfvars  ->  compute_enabled = true

Push-Location infra\envs\prod\10-network
terraform apply -input=false -auto-approve "-var-file=..\common.tfvars" "-var-file=prod.tfvars"
Pop-Location

Push-Location infra\envs\prod\30-cluster
terraform apply -input=false -auto-approve "-var-file=..\common.tfvars" "-var-file=prod.tfvars"
Pop-Location
```

The control plane takes roughly 2 minutes to finish `kubeadm init` on boot and the
worker about 4 to 5 to join. Check with:

```
kubectl get nodes          # both Ready
```

The platform bootstrap association re-fires within 30 minutes and is idempotent,
so no manual re-run is needed unless something looks wrong - then run the document
by hand:

```powershell
aws ssm send-command --region ap-south-1 `
  --instance-ids <control-plane-id> `
  --document-name dpx-prod-platform-bootstrap-doc
```

### What still bills while paused

The instances and the worker are the expensive part and all of it is gone. What
remains is small but not zero:

| Item | Approx. | Note |
|---|---|---|
| EBS gp3 root volumes (3 x 30 GB) | ~USD 2.40 / month | `delete_on_termination` only fires on termination, not on stop |
| ALB | ~USD 0.02 / hour | left running on purpose - destroying it loses the target group wiring |
| S3 buckets, KMS keys, state | negligible | empty, or a few KB |

Deleting the ALB and the volumes would save roughly USD 3 a month, which is not
worth losing the cluster's state and the target group registration to get.

## Phase status

| Phase | State | Evidence |
|---|---|---|
| 0 Conventions | done | `terraform fmt -recursive` clean; every layer root validates |
| 1 Bootstrap | done (prod + qa) | `dpx-tfstate-prod`, `dpx-tfstate-qa`, KMS keys, budgets, GitHub OIDC roles |
| 2 Network | done (prod + qa) | VPC, 2+2 subnets, S3 gateway endpoint, fck-nat; `compute_enabled` flipped back to `true` in prod |
| 3 Security | done (prod + qa) | SGs, node role, KMS, SSM paths; no port 22 anywhere |
| 4 kubeadm cluster | done (prod) | Both nodes `Ready`; worker auto-joins; etcd bucket + snapshot timer live |
| 4 kubeadm cluster | **not applied (qa)** | Needs 4 vCPU that prod's 6 does not leave. See `docs/quota.md` |
| 5 Edge | done (prod) | ALB + target group created, target group ARN wired into 30-cluster |
| 6 Platform bootstrap | done (prod) | Calico `v3.32.2` + Argo CD installed by SSM association; every platform pod `Running` |
| 7 Platform apps | written, not synced | `gitops/prod/apps/*.yaml` exist; Argo CD cannot fetch the repository |
| 8 Project scaffolding | written, not synced | `gitops/prod/projects/scaffold` Helm chart + ApplicationSet |
| Shared Postgres | **written, not synced** | `gitops/prod/apps/shared-postgres/`: `data` namespace, CNPG `Cluster`, backup `CronJob`, three NetworkPolicies. Chart bumped to 0.29.1 (operator 1.30.1) — the pinned 0.28.0 is out of support |
| 60-ops (`data-backups`, `observability`, `scheduler`) | **built, not applied** | `terraform plan` is clean for prod (25 to add) and qa (17 to add). Needs one re-apply of 10-network per env first — see below |
| Scripts | **built** | `up.sh`, `down.sh`, `kubeconfig-via-ssm.sh`, `etcd-restore.sh`; all four pass `bash -n` |
| etcd restore runbook | **written** | [`docs/etcd-restore.md`](etcd-restore.md) |
| CI/CD | **written, inert** | `.github/workflows/terraform.yml` (plan, no credentials needed) and `terraform-apply.yml`. Neither can assume a role yet — see the OIDC note below |

## One thing to do before applying 60-ops

`10-network` gained a `nat_instance_id` output, because 60-ops needs to know which
instance to stop on a schedule and `data.aws_instances` only ever returns *running*
instances — so a tag-based lookup finds nothing while the environment is paused,
which is exactly when this project spends most of its life.

The output does not exist in either environment's 10-network state until that layer
is applied again. Until then 60-ops plans with one warning:

```
Warning: Check block assertion failed
  on main.tf line 138, in check "targets_present":
  138:     condition     = local.nat_instance_id != null
      local.nat_instance_id is null
```

It is a warning, not an error, and nothing else is wrong. Re-apply 10-network in
both environments and it goes away.

## What 60-ops creates

| | prod | qa |
|---|---|---|
| PostgreSQL backup bucket | yes (SSE-KMS, versioned, lifecycle, ACLs off) | yes |
| DLM policy for EBS snapshots | yes, 14-day retention, boot volumes excluded | yes |
| Ops SNS topic + email subscription | yes | yes |
| CloudWatch log groups + agent install (SSM) | yes | no — no control plane yet |
| 6 CloudWatch alarms | yes | no — no cluster, no edge |
| etcd backup-freshness probe + alarm | yes | no |
| Scheduled stop/start | no — prod is out of scope by default | yes — 19:00 Fri/Sun, 08:00 Mon-Fri IST |

The reason so much of qa is absent is that qa has no 30-cluster and no 40-edge, and
each absent dependency produces a resource that is not created rather than one that
is created pointing at nothing. `alarm_count` and `cluster_dependencies` in the
layer's outputs say which is which.

## The OIDC roles still do not exist

`infra/bootstrap` has `create_github_oidc = false` and
`github_repository_owner = "REPLACE_ME"` in both `prod.tfvars` and `qa.tfvars`, so
`dpx-prod-tf-plan`, `dpx-qa-tf-plan`, `dpx-tf-apply-prod` and `dpx-tf-apply-qa` are
not in the account. The workflows are written against those names and will fail at
`configure-aws-credentials` until they are created. The `plan` job's static-analysis
sibling needs no credentials and works today.

The role names are not symmetric on purpose — `dpx-<env>-tf-plan` versus
`dpx-tf-apply-<env>` — because a consistent scheme makes it one character easier to
put the wrong one in a workflow, and that character is the difference between a plan
and a write.

## Current prod cluster

```
NAME             STATUS   ROLES           VERSION
cp-dpx-prod      Ready    control-plane   v1.36.5
ip-10-10-11-37   Ready    <none>          v1.36.5
```

Every pod in every namespace is `Running`. The ALB target is registered but
**unhealthy**, which is correct: Traefik is a Phase 7 app and is not installed yet,
so nothing is listening on NodePort 30080.

## What blocked the rest

### 1. The git repository is private

Argo CD's root Application points at `https://github.com/AdepuShashank/aws_infra`
and reports:

```
ComparisonError=Failed to load target state: failed to generate manifest for
source 1 of 1: rpc error: code = Unknown desc = failed to list refs:
repository not found
```

Verified from the cluster with no credentials:

```
api.github.com/repos/AdepuShashank/aws_infra   -> 404
raw.githubusercontent.com/.../main/README.md   -> 404
git ls-remote https://github.com/...           -> could not read Username
```

GitHub returns 404 to unauthenticated callers for a private repository, which is
indistinguishable from a repository that does not exist. **Do not trust a GitHub
API response from an authenticated machine here** - it will say `private: false`
or the call will be cached, and the answer will be wrong.

Fix, either way:

- make the repository public, or
- give Argo CD a key. The bootstrap script already reads one:

  ```powershell
  aws ssm put-parameter --name /dpx/prod/k8s/argocd-repo-deploy-key `
    --type SecureString --key-id <ssm kms key id> --value "$(cat deploy_key)"
  ```

  The script registers it as a repository Secret and switches the root app to the
  `ssh://` form.

Until then Phase 7 and 8 never sync, and the ALB target stays unhealthy because
Traefik is a Phase 7 app.

### 2. The account has 8 on-demand vCPUs

prod's steady state is 6. prod's MD-default sizing is 8, which AWS accepts
unreliably. qa's NAT plus control plane is 4 more, so **qa cannot run at the same
time as prod** at this quota.

An increase to **16** has been submitted through the Service Quotas API and is
pending AWS Support. These are reviewed manually, so it takes hours rather than
minutes. Check it with:

```powershell
aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A --region ap-south-1
```

Full arithmetic and the quota-increase path are in
[`docs/quota.md`](quota.md); the reasoning is in
[`docs/quota.md`](quota.md); the reasoning is in
[`docs/adr/0002-asg-on-demand-allocation.md`](adr/0002-asg-on-demand-allocation.md).

## Bugs found and fixed while resuming

Four were version-drift bugs in code that had never been exercised on a live
cluster. All are written up in
[`docs/adr/0003-ssm-document-and-join-token.md`](adr/0003-ssm-document-and-join-token.md)
and are commented at the fix site.

| Bug | Symptom | Cause |
|---|---|---|
| `on_demand_allocation_strategy = "prioritized"` | ASG launched fewer instances than desired, reported no error | Provider v6 cannot express override priorities |
| `kubeadm token create` parsed as two fields | Every worker failed to join | k8s 1.36 prints one `<id>.<secret>` field |
| `kubeadm join --control-plane-endpoint` | `unknown flag`, then a misleading "bootstrapToken must be set" | It is an `init`-only flag; the endpoint is positional |
| SSM document `mainType`/`content` | `Unknown property` on the documented shape | This endpoint wants the legacy `mainSteps` shape |

Plus the sizing correction: `t4g.medium` is **2** vCPU, not 1 as the sizing notes
assumed.

## Bugs found while writing 60-ops, GitOps and the scripts

Found by `terraform validate` and `terraform plan` against this account, not by
reading. Each would have been an apply-time or run-time failure.

| Where | Symptom | Cause |
|---|---|---|
| `modules/data-backups/dlm.tf` | `invalid value for description` at plan time | The DLM API rejects a description containing `.` or `:`. Verified character by character against ap-south-1; the CLI reference the error links to does not document it |
| `modules/data-backups/dlm.tf` | `Unsupported block type: default_policy`, `target_tags`, `exclude_boot_volumes` | Provider v6 uses the newer DLM policy language. `policy_type`, `resource_types = ["VOLUME"]`, a `schedule` with `create_rule`/`retain_rule`, and `parameters.exclude_boot_volume` |
| `envs/*/60-ops` | `Unable to find remote state` against 30-cluster and 40-edge | `terraform_remote_state` hard-fails on a key that has never been written, and qa has neither layer. Those two ids are now explicit variables with `check` blocks naming them |
| `envs/*/60-ops` | `data.aws_instances` returned `[]` for a stopped control plane | The data source returns running instances only. Verified with a standalone config. Every tag-based discovery path for the cluster fails while the environment is paused |
| `modules/observability/main.tf` | `slice(split("/", alb_arn), 7, 9)` out of range | The ARN has **four** slash-separated fields, not nine — the `arn:aws:...:loadbalancer` prefix contains none. Derived with two regex `replace` calls instead |
| `modules/scheduler` | `"kms_key_arn" (alias/aws/scheduler) is an invalid ARN` | `kms_key_arn` takes a full ARN. Left unset by default, which is what makes Scheduler use the AWS-managed key |
| `platform-bootstrap/templates/bootstrap-platform.sh.tftpl` | **The root Application would have wrecked the cluster** | The root app is `directory: recurse: true` over `gitops/<env>`, which walks `projects/scaffold/` — a Helm chart. Argo CD renders it with `.Release.Namespace = argocd`, so it would try to apply a Namespace named `argocd` labelled `pod-security.kubernetes.io/enforce: restricted`, plus a default-deny NetworkPolicy cutting Argo CD off from the API server it reconciles against. Fixed with an `exclude` glob |
| `gitops/*/apps/cloudnative-pg.yaml` | Wrong claim, and an out-of-support chart | The header said the ApplicationSet creates the `Cluster`. It does not — the ApplicationSet only makes namespaces. Chart 0.28.0 (operator 1.29.x) is out of support; now 0.29.1 / 1.30.1 |

Two things that looked like bugs and were not, recorded so nobody re-chases them:

- `aws elbv2 describe-load-balancers --query 'LoadBalancers[].Tags'` returns empty
  for this ALB. `aws elbv2 describe-tags` shows all ten tags present. The load
  balancer is fine; the first query is not evidence of anything.
- `terraform -chdir` fails to resolve paths on this Windows machine. That is why
  every layer is driven from inside its own directory with `Push-Location`, and why
  the GitHub workflows use `-chdir` on `ubuntu-latest` where it works.

## Read these before changing anything

| Document | Why |
|---|---|
| [`docs/quota.md`](quota.md) | Every sizing decision follows from the 8-vCPU limit |
| [`docs/adr/0002-asg-on-demand-allocation.md`](adr/0002-asg-on-demand-allocation.md) | Why the worker ASG looks wrong for prod |
| [`docs/adr/0003-ssm-document-and-join-token.md`](adr/0003-ssm-document-and-join-token.md) | Why the bootstrap script and templates look the way they do |
| [`docs/versions.md`](versions.md) | Every pinned version, and how each was verified |
| [`docs/state-layout.md`](state-layout.md) | Layer ordering and state keys |
| [`docs/security-baseline.md`](security-baseline.md) | SG and IAM baseline |
| [`docs/etcd-restore.md`](etcd-restore.md) | Phase 4's untested acceptance item, now written |
| [`infra/modules/README.md`](../infra/modules/README.md) | Which module owns what, and why the etcd bucket is in `cluster` |
