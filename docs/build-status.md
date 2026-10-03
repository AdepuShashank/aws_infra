# Build status

Where the build actually is, as of **2026-10-03**. Phases 0-6 are applied in
prod; 7 and 8 are written but not synced. Two things block the rest, both listed
at the bottom.

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
| Backups / observability / scheduler | not built | `60-ops` layer is still the Phase 0 skeleton |
| Scripts | not built | `scripts/` is empty |
| CI/CD | not built | `.github/` is empty |

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

### 1. There is no git remote

`git log` is empty - this repository has never been committed, and it has no
remote. Argo CD's root Application points at `https://github.com/REPLACE_ME/dpx-infra`
and reports `SYNC STATUS: Unknown`, which is what "repository not found" looks
like from inside the cluster.

Until a remote exists and the `gitops/` tree is pushed:

- Phase 7 and 8 never sync.
- The ALB health check stays failing.
- `gitops_repo_url` in `infra/envs/prod/50-platform/prod.tfvars` still needs
  replacing, along with the `repoURL` in
  `gitops/prod/apps/projects-applicationset.yaml`.

To unblock:

```powershell
# create the repository, then:
git remote add origin <url>
git add -A
git commit -m "Bootstrap DPX AWS infrastructure"
git push -u origin main
```

then set `gitops_repo_url` and re-apply `50-platform`.

### 2. The account has 8 on-demand vCPUs

prod's steady state is 6. prod's MD-default sizing is 8, which AWS accepts
unreliably. qa's NAT plus control plane is 4 more, so **qa cannot run at the same
time as prod** at this quota. Full arithmetic and the quota-increase path are in
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

## Read these before changing anything

| Document | Why |
|---|---|
| [`docs/quota.md`](quota.md) | Every sizing decision follows from the 8-vCPU limit |
| [`docs/adr/0002-asg-on-demand-allocation.md`](adr/0002-asg-on-demand-allocation.md) | Why the worker ASG looks wrong for prod |
| [`docs/adr/0003-ssm-document-and-join-token.md`](adr/0003-ssm-document-and-join-token.md) | Why the bootstrap script and templates look the way they do |
| [`docs/versions.md`](versions.md) | Every pinned version, and how each was verified |
| [`docs/state-layout.md`](state-layout.md) | Layer ordering and state keys |
| [`docs/security-baseline.md`](security-baseline.md) | SG and IAM baseline |
