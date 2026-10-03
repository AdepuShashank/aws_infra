# Build status

Where the build actually is, as of **2026-10-03**. Phases 0-6 are applied in
prod; 7 and 8 are written but not synced. Two things block the rest, both listed
at the bottom.

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

## Read these before changing anything

| Document | Why |
|---|---|
| [`docs/quota.md`](quota.md) | Every sizing decision follows from the 8-vCPU limit |
| [`docs/adr/0002-asg-on-demand-allocation.md`](adr/0002-asg-on-demand-allocation.md) | Why the worker ASG looks wrong for prod |
| [`docs/adr/0003-ssm-document-and-join-token.md`](adr/0003-ssm-document-and-join-token.md) | Why the bootstrap script and templates look the way they do |
| [`docs/versions.md`](versions.md) | Every pinned version, and how each was verified |
| [`docs/state-layout.md`](state-layout.md) | Layer ordering and state keys |
| [`docs/security-baseline.md`](security-baseline.md) | SG and IAM baseline |
