# Pinned versions

Every version below was looked up in the upstream project's official release page / repository
(not guessed). Last verified: **2026-10-02**.

Terraform enforces the versions that matter for correctness (Kubernetes, Calico, Argo CD).
The rest are recorded here so the gitops overlay pins are auditable.

## Toolchain

| Component | Pin | Notes |
|---|---|---|
| Terraform CLI | `>= 1.10.0, < 2.0.0` | `use_lockfile = true` (S3 native locking, no DynamoDB) requires >= 1.10. Local dev uses 1.12.2. |
| `hashicorp/aws` | `~> 6.67` | Lock file committed, so the effective pin is exact. |
| `hashicorp/random` | `~> 3.9` | |
| `hashicorp/tls` | `~> 4.4` | Self-signed ALB certificate (only used when `enable_https = true`). |
| Ubuntu image | `24.04` (noble) arm64, gp3 | Canonical owner `099720109477`. Selected via `data.aws_ami` filter, **not** an SSM public parameter — see [deviations](#deviations-from-infrastructuremd). |

## Kubernetes platform

| Component | Pin | Source of truth |
|---|---|---|
| Kubernetes | **1.36.5** | kubernetes.io/releases — 1.37.1 is newest but Calico does not yet test against it |
| kubeadm / kubelet / kubectl / cri-tools | 1.36.5 | pkgs.k8s.io |
| CNI plugin (loopback) | 1.6.2 | github.com/containernetworking/plugins |
| containerd | shipped by the distro apt repo, `SystemdCgroup=true` | Ubuntu 24.04 noble |

### Why 1.36 and not 1.37

`docs.tigera.io` "System requirements" states Calico v3.32 is tested against Kubernetes **1.34, 1.35, 1.36**
only. Pinning 1.37 would run Calico untested. 1.36 also keeps kubeadm version skew comfortable.

## Cluster add-ons (synced from `gitops/` by Argo CD)

| Component | Pin | Source |
|---|---|---|
| Calico (tigera-operator) | `v3.32.2` | github.com/projectcalico/calico releases; manifests under `manifests/` at that tag |
| Traefik (Helm chart) | `41.4.0`, image `v3.6.2` | github.com/traefik/traefik-helm-chart releases |
| Argo CD (app image) | `v3.5.3` (chart `10.9.6`) | github.com/argoproj/argo-cd releases |
| CloudNativePG (operator chart) | `0.29.1` (operator `1.30.1`) | cloudnative-pg.github.io/charts `index.yaml`, read 2026-10-04. Was `0.28.0`; that line's operator is out of support, and its successor's default database image is PostgreSQL 18, which `shared-postgres` deliberately does not take |
| PostgreSQL (CNPG instance image) | `ghcr.io/cloudnative-pg/postgresql:17.6-system-trixie` | set explicitly in `gitops/<env>/apps/shared-postgres/`. The distro suffix is required — a bare `17.6` does not resolve to an image the operator accepts |
| `amazon/aws-cli` (backup CronJob) | `2.37.9` | hub.docker.com/r/amazon/aws-cli/tags, read 2026-10-04. `<major.minor.patch>` tags are immutable; `latest` explicitly is not |
| `postgres` (pg_dump client image) | `17.6-alpine` | matches the server major.minor, which `pg_dump` requires |
| AWS EBS CSI driver (chart) | `2.64.0` (driver `v1.64.0`) | github.com/kubernetes-sigs/aws-ebs-csi-driver releases |
| metrics-server (chart) | `3.14.0` (app `v0.9.0`) | github.com/kubernetes-sigs/metrics-server releases |
| External Secrets Operator (chart) | `2.10.0` (app `v2.10.0`) | github.com/external-secrets/external-secrets releases |
| aws-node-termination-handler (chart) | `0.27.6` (app `v1.25.6`) | optional, qa spot only |
| kube-prometheus-stack (chart) | `91.8.2` | optional, disabled by default |

### arm64 support (required by the Graviton decision)

| Component | arm64 | Note |
|---|---|---|
| Calico | yes | `calico/node`, `calico/kube-controllers` publish multi-arch manifests |
| Traefik | yes | single manifest is multi-arch |
| Argo CD | yes | official multi-arch manifests since 2.x |
| CloudNativePG | yes | operator image is multi-arch; the PostgreSQL data images must be `arm64v8` |
| EBS CSI driver | yes | official multi-arch |
| metrics-server | yes | official multi-arch |
| External Secrets | yes | official multi-arch |
| aws-node-termination-handler | yes | published as `public.ecr.aws/aws-ec2/...` multi-arch |

Re-verify with `docker buildx imagetools inspect <image>` before promoting any pin.

## Verified retirement status: ingress-nginx

The spec says "verify its retirement status and note it in the docs". Confirmed **retired**:

- Announced 2025-11-11 by Kubernetes SIG Network + the Security Response Committee.
- Best-effort maintenance ended **March 2026**.
- Final release **2026-03-13** (last version supported Kubernetes 1.35 and patched a CVE).
- The repository is archived / read-only. No further bug fixes or security patches will be issued
  for vulnerabilities reported after EOL.

Sources: kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/ and the SIG announcement of
2026-01-29. **Consequence: this project uses Traefik. ingress-nginx must never be added.**

## Deviations from `Infrastructure.MD`

| Spec says | We do | Why |
|---|---|---|
| AMI "via SSM public parameter" | `data.aws_ami` filtered on Canonical owner + Ubuntu noble arm64 gp3 image name | The AWS principal in use has no `ssm:GetParameterByPath`, and the doc forbids hardcoding. The filter resolves to the same image (e.g. `ami-0e376d2aa9c2a801a`, 2026-09-23) and stays current. |
| Latest Kubernetes (1.37.1) | 1.36.5 | Calico does not test against 1.37 yet. See above. |
## Verified 2026-10-03 during Phase 5-6

Re-checked against the upstream registries rather than carried forward, because
two pins were wrong and one did not exist.

| Component | Pin | How it was verified |
|---|---|---|
| Argo CD chart | `10.9.6` -> app `v3.5.3` | Read `index.yaml` from `https://argoproj.github.io/argo-helm`; newest entry is `10.9.6`, `appVersion: v3.5.3`. The MD's `v3.5.2` was one release behind. |
| Helm | `3.20.0`, sha256 `bfb1495...` | Fetched `https://get.helm.sh/helm-v3.20.0-linux-arm64.tar.gz.sha256sum`. The script re-verifies on the node, so the pin is the artifact, not the URL. |
| Calico | `v3.32.2` | All three manifest URLs fetched OK: `manifests/v1_crd_projectcalico_org.yaml` (3.0 MB), `manifests/tigera-operator.yaml`, `manifests/custom-resources.yaml`. |

### Calico manifests are not under tigera-operator

The previous pin was `tigera-operator v1.44.0` with manifests at
`projectcalico/tigera-operator`. That repository does not serve those paths -
`custom-resources.yaml` and `default-crds.yaml` both 404 at that tag. The
manifests live in the **calico** repository under the Calico release tag:

```
https://raw.githubusercontent.com/projectcalico/calico/v3.32.2/manifests/v1_crd_projectcalico_org.yaml
https://raw.githubusercontent.com/projectcalico/calico/v3.32.2/manifests/tigera-operator.yaml
```

The CRD bundle is ~3 MB, which exceeds the API server's request limit for
`kubectl apply`; upstream's own guidance is to use `kubectl create` (or
`replace --force`), which the bootstrap script does.

### The Calico IP pool must match the pod CIDR

Upstream's `custom-resources.yaml` ships `cidr: 192.168.0.0/16`. This cluster's
pod CIDR is `10.200.0.0/16`. Applying the stock manifest produces a cluster where
kubelet asks for addresses from a block the API server never allocated from, and
every pod sits in `ContainerCreating` with no useful error.

The bootstrap script therefore renders the `Installation` resource itself with
`cidr` taken from `30-cluster`'s `pod_cidr` output. `pod_cidr` is declared once, in
`30-cluster`, and `50-platform` reads it through remote state rather than
re-declaring it - a second declaration is a second chance to disagree, and the
disagreement is invisible until pods stop getting addresses.