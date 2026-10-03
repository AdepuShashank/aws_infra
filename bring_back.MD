# bring_back.MD — resume this project from scratch

**Written at the end of the 2026-10-03 session. If you are reading this in a new
session with no memory of that work, start here and nothing else.**

This file is the handoff. It assumes you have read
[`Infrastructure.MD`](Infrastructure.MD) (the specification) but know **nothing**
about what has already been built or what went wrong.

---

## 1. What this is

Terraform for AWS `ap-south-1`, hosting a self-managed **kubeadm** Kubernetes
cluster (no EKS) for 10 small projects, in two environments (`prod`, `qa`).

- Terraform owns everything up to the Kubernetes API server.
- Argo CD owns everything inside the cluster.
- No EKS, no NAT Gateway, no managed RDS, no long-lived AWS keys.
- Graviton arm64 (`t4g`) throughout.

Read next, in this order, when you need the detail:

| File | What it tells you |
|---|---|
| `docs/build-status.md` | Which phases are done, what is blocked |
| `docs/quota.md` | The 8-vCPU limit and every sizing decision |
| `docs/versions.md` | Every pinned version and how it was verified |
| `docs/adr/0001-fck-nat.md` | Why NAT is one instance |
| `docs/adr/0002-asg-on-demand-allocation.md` | Why prod runs 1 worker, not 2 |
| `docs/adr/0003-ssm-document-and-join-token.md` | kubeadm 1.36 + SSM document format traps |
| `docs/adr/0004-calico-crd-replace.md` | The incident that broke the cluster, and its recovery order |

---

## 2. TL;DR — the 5 commands that resume everything

```powershell
# 1. flip the pause flag in BOTH prod layers
#    infra\envs\prod\10-network\prod.tfvars  ->  compute_enabled = true
#    infra\envs\prod\30-cluster\prod.tfvars  ->  compute_enabled = true

# 2. apply the two layers
Push-Location infra\envs\prod\10-network
terraform apply -input=false -auto-approve "-var-file=..\common.tfvars" "-var-file=prod.tfvars"
Pop-Location

Push-Location infra\envs\prod\30-cluster
terraform apply -input=false -auto-approve "-var-file=..\common.tfvars" "-var-file=prod.tfvars"
Pop-Location

# 3. wait ~6 minutes, then check
kubectl get nodes        # both should be Ready
```

That is the whole resume. The rest of this file is detail and warnings.

---

## 3. Current state at handoff

### Paused for cost

`compute_enabled = false` in prod `10-network` and `30-cluster`, both applied.

| Resource | State |
|---|---|
| prod NAT (`i-040fbed3491c1a19c`) | stopped in place |
| prod control plane (`i-0b7d611942ed0a2c3`) | stopped in place |
| prod worker ASG | scaled to 0, instances terminated |
| qa NAT (`i-096700562d53aab75`) | already stopped |

**Stopped, not terminated.** The control plane's root volume persists, so etcd —
and all cluster state — returns with it. You do not need to rebuild anything.

### Verified working at pause

- Both nodes `Ready`, Kubernetes v1.36.5
- Calico v3.32.2, IP pool `10.200.0.0/16`, SNAT rules programmed
- Argo CD chart 10.9.6 (app v3.5.3), all 6 deployments `1/1`
- ALB created, target group created, worker registered as a target

### Phase status

| Phase | State |
|---|---|
| 0 Conventions | done |
| 1 Bootstrap (prod + qa) | done |
| 2 Network (prod + qa) | done |
| 3 Security baseline (prod + qa) | done |
| 4 kubeadm cluster | **prod done**, qa not applied (needs quota) |
| 5 Edge (ALB) | built and applied; target unhealthy because Traefik is Phase 7 |
| 6 Platform bootstrap | done (Calico + Argo CD installed over SSM) |
| 7 Platform apps | **written, never synced** (`gitops/prod/apps/*.yaml`) |
| 8 Project scaffolding | **written, never synced** (`gitops/prod/projects/scaffold`) |
| 60-ops, scripts/, .github/ | still Phase 0 skeletons |

---

## 4. Two blockers — both need a human, neither is a code problem

### Blocker 1: the Git repository is private

Argo CD cannot clone it:

```
ComparisonError=Failed to load target state: failed to generate manifest for
source 1 of 1: rpc error: code = Unknown desc = failed to list refs:
repository not found
```

Verify from the cluster, with no credentials:

```
api.github.com/repos/AdepuShashank/aws_infra   -> 404
raw.githubusercontent.com/.../main/README.md   -> 404
git ls-remote https://github.com/...           -> could not read Username
```

**Fix — pick one:**

**(a) Make the repo public.** Simplest. Then wait for Argo CD's poll (~3 min) or
force it:

```powershell
# annotate the app to trigger an immediate reconcile
aws ssm send-command --region ap-south-1 --instance-ids <cp-id> `
  --document-name AWS-RunShellScript --parameters 'commands=["kubectl -n argocd annotate application root argocd.argoproj.io/refresh=forced --overwrite"]'
```

**(b) Give Argo CD a deploy key.** The bootstrap script already looks for one at
`/dpx/prod/k8s/argocd-repo-deploy-key` and switches the root Application to the
`ssh://` form when it finds it.

```powershell
aws ssm put-parameter --name /dpx/prod/k8s/argocd-repo-deploy-key `
  --type SecureString --key-id <ssm kms key id> --value "$(cat deploy_key)"
```

Get the KMS key id from `terraform output -json` in `20-security`, or:

```powershell
aws kms list-aliases --region ap-south-1 --query "Aliases[?AliasName=='alias/dpx-prod-kms-ssm'].TargetKeyId" --output text
```

Then re-run the bootstrap so it registers the Secret:

```powershell
aws ssm send-command --region ap-south-1 --instance-ids <cp-id> `
  --document-name dpx-prod-platform-bootstrap-doc
```

> **Do not trust a GitHub API response from an authenticated machine about whether
> this repo is public.** That check reported `private: false` and was wrong.
> GitHub returns 404 to unauthenticated callers for a private repo, which is
> indistinguishable from a repo that does not exist. Only the anonymous check
> above is evidence.

Until this is fixed, Phase 7 never syncs, Traefik never installs, and the ALB
target stays unhealthy.

### Blocker 2: the account has 8 on-demand vCPUs

Quota code `L-1216C47A` — "Running On-Demand Standard instances".

```powershell
aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A --region ap-south-1
```

An increase to **16** was submitted and is **pending AWS Support** — reviewed
manually, so hours not minutes.

Why 16, and why you cannot code around 8:

```
prod NAT t4g.nano   2
prod CP  t4g.small  2      = 4
prod workers x2     4      = 8   -> exactly at the limit, which AWS accepts
qa NAT              2            unreliably (observed: 09:57 failed at 8,
qa CP               2      = 4   10:19 succeeded at 10)
```

Both environments running with any workload needs **14**. At 8, prod NAT+CP and
qa NAT+CP alone consume the entire quota, leaving zero for a single worker — and a
cluster with no worker cannot schedule pods.

**Every T4g size from `nano` up to `large` has 2 vCPUs.** The sizing notes in
`Infrastructure.MD` assume 1 for `nano`/`small`; they are wrong, and that
mismatch only shows up as `VcpuLimitExceeded` on a scale-out.

When the quota lands, restore the spec defaults:

```hcl
# infra/envs/prod/30-cluster/prod.tfvars
worker_min_size = 2
worker_max_size = 3
```

then apply. Then apply qa:

```powershell
Push-Location infra\envs\qa\30-cluster
terraform init
terraform apply -input=false -auto-approve "-var-file=..\common.tfvars" "-var-file=qa.tfvars"
Pop-Location
```

and the same for `qa/40-edge` and `qa/50-platform`.

---

## 5. Reaching the cluster

There is no SSH and no bastion, by design. Everything goes through SSM.

```powershell
# a shell on the control plane (interactive)
aws ssm start-session --target-id <instance-id>

# the control plane id, from Terraform (survives stop/start, changes on replace)
Push-Location infra\envs\prod\30-cluster
terraform output -no-color control_plane_instance_id
Pop-Location

# run one command on the control plane (non-interactive)
aws ssm send-command --region ap-south-1 --instance-ids <cp-id> `
  --document-name AWS-RunShellScript --parameters 'commands=["kubectl get nodes"]'

# read the result
aws ssm list-commands --region ap-south-1 --instance-id <cp-id> --max-items 1 --query "Commands[0].CommandId" --output text
```

Argo CD is ClusterIP-only and deliberately not exposed. Port-forward from the
control plane:

```
kubectl -n argocd port-forward svc/argocd-server 8080:80
```

Admin password (SSM SecureString, patched so it survives):

```powershell
aws ssm get-parameter --region ap-south-1 --name /dpx/prod/k8s/argocd-admin-password --with-decryption --query "Parameter.Value" --output text
```

---

## 6. Remaining work

In the order it makes sense:

1. **Unblock the repo** (section 4). Without it nothing below does anything.
2. **Confirm Phase 7 syncs.** Expect Traefik, EBS CSI + encrypted gp3
   StorageClass, metrics-server, External Secrets, CNPG operator, and ten project
   namespaces. Check:
   ```
   kubectl -n argocd get applications,applicationsets
   kubectl get pods -A
   ```
3. **Verify the ALB.** Phase 5's acceptance criterion is "ALB DNS name returns
   Traefik's default 404". Target group ARN is
   `arn:aws:elasticloadbalancing:ap-south-1:580857072251:targetgroup/dpx-prod-alb-tg/2064ef1506b3c01e`.
   ```powershell
   aws elbv2 describe-target-health --region ap-south-1 --target-group-arn <arn> --query "TargetHealthDescriptions[].TargetHealth.State"
   ```
4. **qa `30-cluster`, `40-edge`, `50-platform`** — needs the quota.
5. **`60-ops` layer** — Phase 0 skeleton. Needs: `data-backups` module (S3 buckets
   for etcd + postgres backups, lifecycle, DLM snapshot policy), `observability`
   (CloudWatch alarms, log groups, SNS topic), `scheduler` (EventBridge Scheduler
   stop/start for qa).
6. **`scripts/`** — empty. Spec requires `up.sh`, `down.sh`,
   `kubeconfig-via-ssm.sh`, and an etcd-restore runbook. Also
   `docs/etcd-restore.md`, which does not exist yet and is a Phase 4 acceptance
   item that was never written.
7. **`.github/workflows/`** — empty. The GitHub OIDC provider and plan/apply roles
   already exist in `infra/bootstrap`; nothing uses them yet.
8. **Shared Postgres** — deliberately deferred at the user's request. Needs a
   `postgresql.cnpg.io/v1` `Cluster` in a `data` namespace. Note
   `gitops/*/apps/cloudnative-pg.yaml` currently contains only the operator, and
   its header comment wrongly claims the Cluster "is created by the
   ApplicationSet" — it is not. The ApplicationSet only creates per-project
   namespaces. Fix that comment or add the Cluster.

---

## 7. Gotchas that cost hours — do not rediscover these

**PowerShell mangles `-var-file`.** Unquoted, PowerShell hands Terraform a bare
`=..\common.tfvars` positional argument and it fails with
`Too many command line arguments`. Always quote:
`"-var-file=..\common.tfvars"`.

**`terraform -chdir` is broken on this machine** (`chdir` path resolution fails).
Use `Push-Location` / `Pop-Location` instead.

**SSM serialises commands per instance.** One stuck command blocks every later
one. If a `send-command` sits `Pending` forever, `cancel-command` it. Always pass
`--max-items 1` to `list-commands`, or `$cid` captures every id and the next
`aws` call fails with `Unknown options`.

**`kubectl exec` and `kubectl logs` are broken** against this cluster —
`remote error: tls: internal error` from the apiserver to the kubelet. Pod events,
`kubectl get`, `kubectl describe` and `kubectl patch` all work. Use those, and
`aws ssm get-command-invocation` for anything needing output.

**`templatefile` claims every `${...}`** in a `.tftpl` before bash sees it. A
bash parameter expansion like `${VAR:-default}` is a Terraform syntax error. Use
plain `$VAR` with the variable initialised separately, or escape as `$${VAR}`.
This produced three separate plan-time failures in one afternoon.

**The control plane user-data is at EC2's 16,384-byte limit.**
`user-data-guard.tf` fails the plan if it crosses. Keep comments in
`control-plane.sh.tftpl` short; rationale belongs in `control-plane.tf`.

**Never `replace --force` a CRD to install a CRD.** That is what broke the
cluster on 2026-10-03 — see `docs/adr/0004-calico-crd-replace.md`. The bootstrap
script no longer does it, but do not reintroduce it.

**The ASG must not use `on_demand_allocation_strategy = "prioritized"`.**
Provider v6 cannot express override priorities, so AWS accepts the policy and then
silently fails to allocate capacity — the group launches fewer instances than
desired, reports every activity as `Successful`, and never retries. Use
`"lowest-price"` (hyphenated; the camelCase form is rejected outright).

**`ssm:AddTagsToResource` vs `ssm:ListTagsForResource`.** IAM will report the
latter as allowed while SSM still denies it. Do not put `tags` on an SSM
parameter; the name already encodes project and environment.

---

## 8. Repo conventions

- Every resource tagged `Name, Project, Env, Layer, Owner, ManagedBy=terraform, CostCenter`.
- Names are `project-env-name`, from `modules/naming`. Never hand-rolled.
- No account id, region or CIDR hardcoded in a module — variables with validation.
- `terraform fmt`, `validate`, `tflint`, `checkov` must pass.
- Layers apply in order: `10-network` → `20-security` → `30-cluster` →
  `40-edge` → `50-platform` → `60-ops`. Each fails with a named message if its
  dependency is missing.

Current branch: `main`, tracking `origin/main`
(`https://github.com/AdepuShashank/aws_infra.git`).