# aws_infra

Production-style, cost-lean AWS infrastructure for hosting 10 small projects on a
self-managed **kubeadm** Kubernetes cluster, with separate `prod` and `qa`
environments.

Terraform for everything up to the cluster API server; Argo CD for everything
inside it. No EKS, no NAT Gateway, no managed RDS, no long-lived AWS keys.

| | |
|---|---|
| Region | `ap-south-1` (Mumbai) |
| Instances | Graviton arm64 (`t4g`), control plane `t4g.small`, workers `t4g.medium` |
| CNI | Calico `v3.32.2` (NetworkPolicy enforced) |
| Ingress | Traefik `41.4.0` on a NodePort behind one ALB |
| GitOps | Argo CD chart `10.9.6` (Argo CD `v3.5.3`) |
| State | S3 backend, native lockfile (`use_lockfile`), **no DynamoDB** |
| Access | SSM Session Manager only - no SSH, no bastion, no key pairs |

## Current state

Phases 0-6 are applied in **prod**; both nodes are `Ready` and every platform pod
is running. Phases 7-8 are written but not synced, because there was no git remote
to sync from. See **[`docs/build-status.md`](docs/build-status.md)** for the phase
table and what is outstanding.

```
NAME             STATUS   ROLES           VERSION
cp-dpx-prod      Ready    control-plane   v1.36.5
ip-10-10-11-37   Ready    <none>          v1.36.5
```

## Layout

```
infra/
├── bootstrap/           # state buckets, KMS, GitHub OIDC roles, budgets (local state)
├── modules/             # network, cluster, security, edge, platform-bootstrap, ...
└── envs/{prod,qa}/      # layered roots, applied in order:
                         #   10-network 20-security 30-cluster
                         #   40-edge    50-platform 60-ops
gitops/{prod,qa}/        # what Argo CD syncs: platform apps + project scaffold
scripts/                 # up.sh, down.sh, kubeconfig-via-ssm.sh, etcd-restore
docs/                    # architecture, ADRs, quota, versions
.github/workflows/       # CI/CD (not built yet)
```

Each layer has its own state key, `<env>/<layer>/terraform.tfstate`, so one
layer cannot corrupt another.

## Applying a layer

`bootstrap` keeps local state on purpose - it creates the bucket every other layer
uses. Everything else runs from S3.

```powershell
# once per layer, per environment
cd infra\envs\prod\10-network
terraform init

# plan and apply. Quote the -var-file arguments: unquoted, PowerShell hands
# Terraform a bare "=..\common.tfvars" positional argument.
terraform plan   -input=false "-var-file=..\common.tfvars" "-var-file=prod.tfvars"
terraform apply  -input=false -auto-approve "-var-file=..\common.tfvars" "-var-file=prod.tfvars"
```

Layers must be applied in order. Each one fails with a named message if the layer
it depends on is missing, rather than silently producing a broken environment.

## Pausing an environment

Set `compute_enabled = false` in the environment's `10-network` and `30-cluster`
tfvars and apply those two layers. The NAT and control plane stop in place, the
worker ASG scales to zero and terminates its disposable workers. Backup buckets
and remote state are untouched. Set it back to `true` to resume.

## Reaching things

There is no SSH and no bastion, so everything goes through SSM:

```powershell
# a shell on the control plane
aws ssm start-session --target-id <instance-id>

# kubectl, from the control plane
aws ssm start-session --target-id <instance-id> --document-name AWS-RunShellScript

# Argo CD, which is ClusterIP-only and deliberately not exposed
# (run on the control plane)
kubectl -n argocd port-forward svc/argocd-server 8080:80
```

Instance ids come from `terraform output` in `30-cluster`, or from `nodes` in
[`docs/build-status.md`](docs/build-status.md).

## Read before changing

| Document | Why it matters |
|---|---|
| [`docs/build-status.md`](docs/build-status.md) | What is built, what is not, what is blocking |
| [`docs/quota.md`](docs/quota.md) | **The account has 8 on-demand vCPUs.** Every sizing decision follows from this, and qa cannot run at the same time as prod |
| [`docs/adr/0001-fck-nat.md`](docs/adr/0001-fck-nat.md) | Why NAT is a single instance |
| [`docs/adr/0002-asg-on-demand-allocation.md`](docs/adr/0002-asg-on-demand-allocation.md) | Why the worker ASG looks wrong for prod |
| [`docs/adr/0003-ssm-document-and-join-token.md`](docs/adr/0003-ssm-document-and-join-token.md) | Why the bootstrap script and templates look the way they do |
| [`docs/security-baseline.md`](docs/security-baseline.md) | SG and IAM baseline; port 22 appears nowhere |
| [`docs/versions.md`](docs/versions.md) | Every pinned version and how each was verified |
| [`docs/state-layout.md`](docs/state-layout.md) | Layer ordering and state keys |

## Conventions

- Every resource is tagged `Name, Project, Env, Layer, Owner, ManagedBy=terraform, CostCenter`.
- Names are `project-env-name`, produced by `modules/naming`. Never hand-rolled.
- No account id, region or CIDR is hardcoded in a module. Values are variables
  with validation.
- `terraform fmt`, `terraform validate`, `tflint` and `checkov` must pass.
  See [`.pre-commit-config.yaml`](.pre-commit-config.yaml).

## Known gaps

| Gap | Effect |
|---|---|
| No git remote for Argo CD | Phases 7-8 never sync; the ALB target stays unhealthy because Traefik is a Phase 7 app |
| 8-vCPU on-demand quota | Prod runs 1 worker instead of 2; qa cannot run alongside prod. Raising the quota to 16 restores the spec defaults with no code change |
| `60-ops` layer is a skeleton | No DLM snapshot policy, CloudWatch alarms or EventBridge stop/start schedules |
| `scripts/` is empty | No `up.sh`, `down.sh` or `kubeconfig-via-ssm.sh` |
| `.github/` is empty | No CI/CD. The OIDC roles exist in `infra/bootstrap` but nothing uses them yet |
| IRSA not wired | The account has no cluster OIDC provider, so External Secrets falls back to the node role. See `gitops/*/apps/external-secrets.yaml` |

[`Infrastructure.MD`](Infrastructure.MD) is the specification this was built from.
