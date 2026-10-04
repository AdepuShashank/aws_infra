# etcd restore

The procedure for putting a Kubernetes cluster back from an S3 snapshot, for the
`prod` or `qa` environment in this repository.

Read this before running anything. `scripts/etcd-restore.sh` does the mechanical
steps; this document explains what each one is for and what it costs, which is what
you need at 2am when the script is asking you to confirm.

- **When you need this**: etcd is unrecoverable. Not "has a problem" — the control
  plane holds one member, so losing its data directory is losing the cluster. Every
  Secret, ConfigMap, Deployment, Application and custom resource is in there.
- **What triggers it**: a lost or corrupted data directory, a bad upgrade, or a
  control-plane instance replaced with the wrong root volume. Not a crashed etcd —
  that restarts.
- **RPO**: the snapshot interval, six hours. See `snapshot_hours` in
  `infra/modules/cluster/variables.tf`.
- **RTO**: about 15 minutes, most of it waiting.

---

## 1. Before you restore anything

### 1.1 Confirm the snapshot is the problem

Not every etcd symptom is data loss, and a restore is a large hammer.

```bash
# From an SSM session on the control plane:
systemctl status etcd --no-pager
journalctl -u etcd -n 100 --no-pager

ls -la /var/lib/etcd/member/snap/db
```

A data directory with a `db` file of **0 bytes** is corruption. A directory with
`member/snap/` missing entirely means etcd was never initialised here, which is a
different problem with a different fix.

### 1.2 Confirm you have a snapshot, and that it is readable

```bash
./scripts/etcd-restore.sh prod list
./scripts/etcd-restore.sh prod verify
```

`verify` copies the newest snapshot to the control plane and runs
`etcdutl snapshot status` against it. A snapshot that fails this is not restorable,
and finding that out now costs a minute rather than after you have stopped etcd.

Do this step even if you are in a hurry. A truncated upload produces a `.db` file of
the right name and a plausible size, and `snapshot restore` only discovers it is
incomplete after it has already consumed the file.

### 1.3 Decide whether you actually want a restore

This is the step people skip, and it is the one that matters, because a restore is
**not** a repair — it is a time machine, and it goes backwards past everything that
happened since the snapshot.

Restoring a six-hour-old snapshot discards:

| | Consequence |
|---|---|
| Secrets rotated since | **The old credential comes back.** If you rotated a leaked password in the last six hours, the leaked one becomes valid again. |
| Changes made directly in the cluster | Reverted. If anyone has been debugging with `kubectl patch`, that work is gone. |
| Objects created since | Gone, including anything Argo CD would immediately recreate — and that re-creation is what decides whether you get your old state or a fight between Argo CD and a restored cluster. |
| The kubeadm join token | Reverted to a token that is very likely expired. See §4. |

If the problem is one broken object rather than the whole data directory, prefer
fixing that object. Restoring to repair a single ConfigMap throws away six hours of
everything else to get it.

### 1.4 Snapshot the current state first

This is what makes the restore reversible. `scripts/etcd-restore.sh` does it
automatically in step 1, but if you are restoring by hand from this document, do it
explicitly and **note the name**:

```bash
# On the control plane, over an SSM session:
/usr/local/bin/k8s-etcd-snapshot
aws s3 ls s3://dpx-prod-etcd-backups/ --region ap-south-1 | grep pre-restore
```

The name will be something like `etcd-20261004T091422Z.db`. Write it down. It is the
difference between "roll back" and "we are now running on a snapshot from Tuesday".

---

## 2. What the restore actually does

Replacing the contents of etcd on the control plane. Specifically:

1. Stop the `etcd` systemd unit. **Not** kubelet, **not** the instance. Stopping
   kubelet makes the node NotReady and starts the control plane being evicted;
   stopping the instance means a cold-start path you then have to debug on top of the
   restore.
2. Restore the snapshot into a **scratch** directory and check it. `etcdutl snapshot
   restore` generates a new member ID and rewrites the whole data directory, so
   doing it directly over the live one destroys the old state before the new state is
   known good.
3. Move the current `/var/lib/etcd` aside, to `/var/lib/etcd-pre-restore`. Renamed,
   not deleted: instant, reversible, and it keeps file ownership and permissions.
4. Restore into `/var/lib/etcd`, fix ownership, start etcd.
5. Wait for kube-apiserver, then check `/readyz`.

### Why not `etcdctl snapshot restore`

`etcdctl snapshot restore` is deprecated for this and `etcdutl snapshot status` is
the current tool for validating a snapshot file. Both are installed on the control
plane by `cloud-init` (see `templates/control-plane.sh.tftpl`), matched to the etcd
version kubeadm deployed. The restore does **not** use a running member's data — it
writes a standalone member directory, and the kubelet/apiserver static pods are
restarted by the systemd unit coming back up.

### Why not restore on a second node and replicate

Because there is one member. Adding a second etcd to "restore more safely" means
changing the kubeadm configuration, which is a larger change than the problem
warrants.

---

## 3. Running it

```bash
./scripts/etcd-restore.sh prod restore etcd-20261004T060000Z.db
```

It will print what it is about to do and require you to type `restore` in lower case.

Under the hood, each step is an `aws ssm send-command` against the control plane
with its output read back through `aws ssm get-command-invocation`. SSM rather than
SSH because this project has no SSH, and rather than `kubectl exec` because the
exec streaming path to the kubelet is broken here (`remote error: tls: internal
error`) — see §6.

If you prefer to do it by hand, over an SSM session on the control plane:

```bash
systemctl stop etcd

rm -rf /var/lib/etcd-restore-check
aws s3 cp s3://dpx-prod-etcd-backups/etcd-20261004T060000Z.db /tmp/snap.db \
  --region ap-south-1
etcdutl snapshot status /tmp/snap.db -w table

etcdutl snapshot restore /tmp/snap.db --data-dir /var/lib/etcd-restore-check
ls /var/lib/etcd-restore-check/member      # must list snap/ and wal/

mv /var/lib/etcd /var/lib/etcd-pre-restore
mv /var/lib/etcd-restore-check /var/lib/etcd
chown -R root:root /var/lib/etcd
chmod 700 /var/lib/etcd

systemctl start etcd
kubectl get --raw='/readyz?verbose'
```

---

## 4. After the restore

### 4.1 The join token

The restored etcd contains the join token as it was at snapshot time. kubeadm's
default token TTL is 15 minutes, so it is certainly expired. The control plane's
`k8s-join-token.timer` regenerates and republishes it within ~30 minutes, and any
worker that has joined since will not rejoin until it does.

Force it rather than waiting:

```bash
./scripts/kubeconfig-via-ssm.sh prod > /tmp/kc
KUBECONFIG=/tmp/kc kubectl delete node <worker-name>
```

The ASG replaces the worker, and the replacement reads the current token from SSM.
Note that `kubectl delete node` only removes the node object — delete the EC2
instance too if you want a fresh kubelet state, since the kubelet's on-disk view is
not part of the etcd snapshot.

### 4.2 Argo CD will re-sync, and that is a feature

Argo CD's own state lives in etcd, so it comes back too — along with the record of
what it last synced. It will compare that against the repository and re-apply the
difference, which means:

- Anything committed since the snapshot gets applied.
- Anything patched directly into the cluster since the snapshot gets reverted.

Expect the cluster to look different from what you remember within a few minutes of
Argo CD reconciling. Check:

```bash
KUBECONFIG=/tmp/kc kubectl -n argocd get applications
```

### 4.3 Do not run `terraform apply`

Terraform state was written when the instances were created. It does not know that
etcd went back in time, and it describes infrastructure, not the data inside it — so
a plan in `30-cluster` will usually come back **empty**, which is correct and is not
evidence that anything is fine.

If a plan *does* want to recreate instances, the instance ids in state and reality
have diverged. That is a question for a human; read the plan, do not approve it with
`-auto-approve`.

### 4.4 The root volume

etcd's data is not the only cluster state on the control plane. The kubeadm PKI in
`/etc/kubernetes/pki` is not in the snapshot, and a restored etcd whose peers present
certificates from a *different* CA is a cluster that comes up and then fails in ways
that look like network problems.

In this project the etcd snapshot and the root volume come from the same instance at
roughly the same time, so they should agree. Verify rather than assume — the check is
that the API server reaches `/readyz` and `kubectl get nodes` lists both nodes.

---

## 5. Rolling back

If the restore was the wrong call, and the data directory from before it is still on
disk:

```bash
systemctl stop etcd
rm -rf /var/lib/etcd
mv /var/lib/etcd-pre-restore /var/lib/etcd
systemctl start etcd
```

Or from the pre-restore snapshot taken in §1.4:

```bash
./scripts/etcd-restore.sh prod verify pre-restore-20261004T091422Z.db
./scripts/etcd-restore.sh prod restore pre-restore-20261004T091422Z.db
```

Rollback is only available while `/var/lib/etcd-pre-restore` exists. The script leaves
it in place deliberately and prints a warning about it; if you delete it, the only way
back is a snapshot.

---

## 6. Why SSM and not SSH

There is no bastion and no SSH key pair anywhere in this project. Port 22 is closed by
construction — `docs/security-baseline.md` asserts it, and `modules/security` has an
output whose only purpose is to be reviewed for the absence of port 22. The only
access path is SSM Session Manager, over a node role scoped to this environment's
Parameter Store prefix.

`kubectl exec` and `kubectl logs` are also unusable against this cluster: the API
server reports `remote error: tls: internal error` on the streaming path to the
kubelet. `kubectl get`, `describe`, `patch` and pod events all work. Anything needing
command output goes through `aws ssm get-command-invocation`, which is what
`etcd-restore.sh` does.

---

## 7. Testing this procedure

Phase 4's acceptance criterion is that this restore is tested, not written. On a
throwaway environment, where nothing is lost by trying:

```bash
# 1. Prove the snapshot path works without touching the live data directory.
./scripts/etcd-restore.sh qa verify
./scripts/etcd-restore.sh qa restore <oldest-snapshot-key>

# 2. Confirm the cluster came back and is internally consistent.
./scripts/kubeconfig-via-ssm.sh qa > /tmp/kc
KUBECONFIG=/tmp/kc kubectl get nodes
KUBECONFIG=/tmp/kc kubectl get pods -A
KUBECONFIG=/tmp/kc kubectl -n argocd get applications

# 3. Prove the rollback path too. An untested rollback is not a rollback.
```

Restoring a deliberately old snapshot and checking that `kubectl get pods -A` still
returns a coherent cluster is the only evidence that any of this works. Everything
else in this document is a claim.

---

## 8. Related

| Document | What it covers |
|---|---|
| [`scripts/etcd-restore.sh`](../scripts/etcd-restore.sh) | The script this document describes |
| [`modules/cluster/etcd-backups.tf`](../infra/modules/cluster/etcd-backups.tf) | The bucket: encryption, lifecycle, policy |
| [`modules/data-backups/`](../infra/modules/data-backups) | The postgres bucket and the DLM policy |
| [`modules/observability/`](../infra/modules/observability) | The `dpx-<env>-etcd-snapshot-stale` alarm |
| [`docs/security-baseline.md`](security-baseline.md) | Why there is no SSH |
| [`docs/adr/0004-calico-crd-replace.md`](adr/0004-calico-crd-replace.md) | A real incident in this cluster, and its recovery order |
