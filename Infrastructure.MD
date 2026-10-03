# ROLE
You are a senior platform/DevOps engineer. Build a production-style, cost-lean AWS infrastructure with Terraform for hosting 10 small projects on a self-managed kubeadm Kubernetes cluster, with separate `prod` and `qa` environments. This is a portfolio project that will be spun up and torn down often, so everything must be repeatable and cheap to run.

# SCOPE
IN SCOPE: AWS infrastructure, kubeadm cluster, cluster platform add-ons (via Argo CD), per-project namespace scaffolding, shared Postgres, backups, security baseline, observability baseline, cost controls, GitHub Actions CI/CD for the infra, documentation.
OUT OF SCOPE: deploying the 10 projects' real frontend/backend code. Only create a throwaway smoke-test workload to validate the platform, and remove it after validation.

# FIXED DECISIONS (do not change without asking)
- Cloud/region: AWS, ap-south-1 (Mumbai), variable-driven.
- IaC: Terraform >= 1.10. State in S3 with native locking (`use_lockfile = true`). NO DynamoDB.
- Kubernetes: self-managed with **kubeadm** on EC2 (no EKS). 1 control plane + worker Auto Scaling Group.
- CNI: Calico (must enforce NetworkPolicy).
- Ingress: Traefik (NodePort service) behind one ALB. Do NOT use ingress-nginx (verify its retirement status and note it in the docs).
- GitOps: Argo CD. CI/CD: GitHub Actions with OIDC (no long-lived AWS keys).
- No domain yet: Route 53/ACM are optional behind `domain_name = null`. Default is HTTP on the ALB DNS name, with optional HTTPS via an imported self-signed cert behind a flag.
- Lean: no WAF, no GuardDuty, no Secrets Manager, no NAT Gateway, no EKS, no managed RDS.
- Workload shape: 10 projects, each in its own namespace, each with 1 frontend pod, 1 backend pod, and one database on a SHARED Postgres. Pods are tiny (<256 MB).
- Use arm64 (Graviton, t4g) instances. Check all add-on images support arm64.

# ENVIRONMENTS
| Setting | prod | qa |
|---|---|---|
| VPC CIDR | 10.10.0.0/16 | 10.20.0.0/16 |
| AZs | 2 | 2 subnets, 1 active NAT |
| Control plane | t4g.small (variable; allow t4g.medium) | t4g.small |
| Workers | 2 x t4g.medium on-demand (ASG min2/max3) | 1 x t4g.medium spot (ASG min0/max2) |
| Postgres instances | 1 (variable; 2 optional) | 1 |
| Scheduled stop | off | on (nights/weekends, variable) |
All values are variables with these defaults. Same modules, different `tfvars`.

To pause compute without destroying infrastructure, set `compute_enabled = false`
in the environment's `10-network` and `30-cluster` tfvars and apply those layers.
The NAT and control-plane instances stop in place; the worker ASG scales to zero
and terminates its disposable worker instances. Set it back to `true` and apply
to restart the instances and recreate the workers. Persistent backup buckets
and Terraform state are not removed.

# REPO LAYOUT
```
infra/
├── bootstrap/        # state bucket, KMS, GitHub OIDC provider+roles, AWS Budgets
├── modules/
│   ├── network/      # VPC, public/private subnets, route tables, S3 gateway endpoint, fck-nat, flow logs (toggle)
│   ├── security/     # SGs, IAM roles/instance profiles, KMS keys, SSM param paths
│   ├── k8s-nodes/    # control plane EC2 (fixed ENI/private IP), worker ASG, launch templates, cloud-init
│   ├── edge/         # ALB, listeners, target group, optional Route53/ACM
│   ├── platform-bootstrap/ # SSM-driven install of Calico + Argo CD + root app
│   ├── data-backups/ # S3 buckets (etcd, postgres), lifecycle, DLM snapshot policy
│   ├── observability/# CloudWatch alarms, log groups, SNS topic
│   └── scheduler/    # EventBridge Scheduler stop/start (qa)
├── envs/{prod,qa}/   # layered roots: 10-network, 20-security, 30-cluster, 40-edge, 50-platform, 60-ops
├── gitops/           # what Argo CD syncs (platform apps + project scaffolding)
├── scripts/          # up.sh, down.sh, kubeconfig-via-ssm.sh, etcd-restore runbook
├── .github/workflows/
└── docs/
```
Each layer has its own state key: `<env>/<layer>/terraform.tfstate`. Share outputs via `terraform_remote_state` or SSM parameters.

# TERRAFORM STANDARDS
- Pin Terraform and provider versions; commit `.terraform.lock.hcl`.
- Every resource tagged: Project, Env, Owner, ManagedBy=terraform, CostCenter.
- Variables typed and validated; outputs documented; no hardcoded account IDs, regions or CIDRs.
- `terraform fmt`, `validate`, TFLint and Checkov must pass.
- Look up CURRENT stable versions (Kubernetes minor, Calico, Traefik, Argo CD, CNPG, etc.) from official docs and pin them as variables. Do not guess versions.

# BUILD PHASES (follow this order; each phase has acceptance criteria)

## Phase 0 - Conventions
Create the repo skeleton, pre-commit config, naming/tagging locals, README.
Accept: `terraform fmt -check` and `validate` pass on empty layers.

## Phase 1 - Bootstrap (local state first, then migrate)
- S3 state bucket: versioning, SSE-KMS, block public access, TLS-only policy, lifecycle for noncurrent versions, access logging optional.
- GitHub OIDC provider and IAM roles: `plan` (read-only + state access) and `apply` (scoped admin per env), trust restricted to the repo and branches/environments.
- AWS Budgets with email alerts (80%/100% per env, `alert_email` variable).
Accept: backend migrated to S3, a second `plan` acquires and releases the lock file, no static AWS keys exist.

## Phase 2 - Network
VPC, 2 public subnets (ALB, fck-nat), 2 private subnets (nodes), route tables, S3 gateway endpoint, **fck-nat** (ASG of t4g.nano) instead of NAT Gateway, optional flow logs to CloudWatch (14-day retention).
Accept: private instance can reach the internet through fck-nat; no public IPs on nodes.

## Phase 3 - Security baseline
- SGs: ALB (80/443 from `allowed_cidrs`), workers (NodePorts only from ALB SG; node-to-node all; CP API 6443 from workers/CP only), CP.
- IAM instance profiles: SSM core, scoped SSM Parameter Store read/write under `/<env>/k8s/*`, EBS CSI permissions, S3 access limited to the etcd and postgres backup buckets, CloudWatch agent.
- KMS keys for EBS and SSM SecureStrings. IMDSv2 required, EBS encrypted, no SSH keys, no bastion (SSM Session Manager only).
Accept: `aws ssm start-session` works to every node; no port 22 open.

## Phase 4 - kubeadm cluster
- Ubuntu 24.04 arm64 AMI via SSM public parameter. Control plane uses a dedicated ENI with a fixed private IP as `controlPlaneEndpoint` so a rebuilt node keeps the same endpoint.
- cloud-init: disable swap, kernel modules/sysctls, containerd (SystemdCgroup=true), pinned kubeadm/kubelet/kubectl, `kubeadm init` from a config file (pod/service CIDRs must not overlap the VPC).
- Control plane runs a systemd timer that regenerates a short-lived join token every ~30 min and writes the join command and CA hash to SSM SecureString. Workers (ASG launch template) read it and `kubeadm join`. Workers attach to the ALB target group via the ASG.
- Admin kubeconfig stored in SSM SecureString (retrieved with `scripts/kubeconfig-via-ssm.sh`).
- etcd snapshot timer (every 6h) to the S3 etcd bucket, 14-day lifecycle. Write `docs/etcd-restore.md` and test the restore steps.
Accept: `kubectl get nodes` shows all nodes Ready (via SSM port-forward or session); replacing a worker via ASG auto-joins.

## Phase 5 - Edge
ALB in public subnets, HTTP listener, target group on Traefik's NodePort with a health check on Traefik's ping endpoint, SG-restricted. Feature flags: `enable_https` (imported self-signed cert) and `domain_name` (Route 53 + ACM + redirect). When `domain_name = null`, create none of the DNS/ACM resources.
Accept: ALB DNS name returns Traefik's default 404 (healthy targets).

## Phase 6 - Platform bootstrap (Terraform -> SSM -> cluster)
Because the API server is private, Terraform must NOT use kubernetes/helm providers from the CI runner. Use SSM Run Command/associations on the control plane to: install Calico, install Argo CD (pinned Helm chart, not publicly exposed), create the repo credentials if the repo is private (deploy key from SSM), and create the root app-of-apps pointing at `gitops/<env>`.
Accept: Argo CD healthy; root app syncing; access only via SSM port-forward.

## Phase 7 - Platform apps (in `gitops/`, synced by Argo CD)
Per env overlay, sync-wave ordered:
1. AWS EBS CSI driver + default gp3 StorageClass (encrypted)
2. metrics-server
3. Traefik (NodePort, resource-limited)
4. External Secrets Operator + ClusterSecretStore using SSM Parameter Store
5. CloudNativePG operator
6. Optional (disabled by default): kube-prometheus-stack, aws-node-termination-handler (enable for qa spot)
Accept: all apps Synced/Healthy; platform pods fit inside node capacity.

## Phase 8 - Project scaffolding
Use an ApplicationSet (list generator over a `projects` list, default `project-01..project-10`, renameable) to create per project:
- Namespace with Pod Security Admission `restricted`, standard labels
- ResourceQuota (defaults: 10 pods, requests 500m CPU/512Mi, limits 1Gi mem) and LimitRange (default request 50m/64Mi, limit 250m/256Mi) - all overridable
- ServiceAccount and RBAC (namespace admin role for a project group)
- NetworkPolicies: default-deny ingress+egress; allow DNS to kube-dns; allow ingress from the Traefik namespace to pods labeled `a

pp.kubernetes.io/component` = `frontend`/`backend`; allow frontend -> backend; allow backend -> shared Postgres (port 5432) in the `data` namespace; optional backend egress 443 to
