# 0004 - Calico CRD install must be a check, never a destructive replace

**Status:** accepted, 2026-10-03
**Relates to:** `infra/modules/platform-bootstrap/templates/bootstrap-platform.sh.tftpl`

## What happened

The bootstrap script installed Calico's CRDs like this:

```bash
kubectl create -f "$MANIFESTS/v1_crd_projectcalico_org.yaml" ||
  kubectl replace --force -f "$MANIFESTS/v1_crd_projectcalico_org.yaml"
```

The `|| replace --force` was there for re-runs: `kubectl create` on an existing
resource fails, so the fallback was supposed to make the step idempotent.

It does the opposite. `replace --force` deletes the object and creates it again.
Re-running the script against a cluster that already had Calico therefore deleted
and recreated roughly 3 MB of tigera CRDs **while tigera-operator was actively
serving them**. CRD timestamps confirmed it: most `*.operator.tigera.io` CRDs went
from a 12:27 timestamp to 13:28, mid-run.

## What it cost

Deleting a CRD deletes every object of that kind. The cluster came back with both
nodes still `Ready` and every existing pod still `Running` - which is what made it
easy to keep going - but:

- **No `IPPool` CR existed afterwards.** The `Installation` object survived (its
  CRD was not in the replaced set) and still said `cidr: 10.200.0.0/16`, so
  `kubectl get installation` looked perfectly healthy. But the operator never
  recreated the pool, and every new pod failed with:

  ```
  plugin type="calico" failed (add): cannot find a qualified ippool
  ```

- **Pods had no egress.** `cali-nat-outgoing` on the worker was an empty chain -
  no MASQUERADE rules at all - because there was no pool for Felix to program from.

- **`argocd-repo-server` crash-looped.** Its liveness probe is
  `GET /healthz?full=true` with `timeout=1s`. That check does real git I/O against
  configured repositories; with no egress it hangs past one second and the kubelet
  kills the container. 18 restarts.

- **`helm upgrade --install --wait` then failed** waiting for that deployment,
  which is why the bootstrap run never reached the step that fixes the root
  Application's `repoURL`.

## The lesson

Two of these failures pointed somewhere other than their cause:

- `helm --wait` failing says nothing about CNI.
- `Installation` reading correctly says nothing about whether the pool exists.

The single broken thing was three layers down, and the only place it was visible
was a pod event on a throwaway test pod. **Check the CNI's actual data, not the
operator's desired state** - `kubectl get ippools` answered in one call what
`kubectl get installation` insisted was fine.

## Decision

The CRD step is now an existence check:

```bash
if kubectl get crd installations.operator.tigera.io >/dev/null 2>&1; then
  log "Calico already installed, skipping CNI install"
else
  # create CRDs, create operator, wait
fi
```

A CRD that already exists is the outcome the section wanted, so there is nothing to
do. The `Installation` resource is still applied unconditionally, because that is
the one object whose content must win over whatever is there - it is the source of
the pod CIDR and the SNAT setting.

**Nothing in this stack should ever `delete` a CRD to install a CRD.** Upstream's
own guidance is `kubectl create`, and for this bundle specifically it is also
`replace --force` that is dangerous: on a 3 MB CRD it deletes first and fails
afterwards, which leaves the cluster worse than not having run.

## Recovery

The state this leaves behind is repairable but not by re-running the script. The
operator's informer cache is stale, so it must be restarted, and the missing pool
recreated:

1. `kubectl delete installation.operator.tigera.io default --ignore-not-found`
2. Delete the tigera CRDs. **This hangs** while the wedged operator holds
   finalizers - remove the `finalizer.operator.tigera.io` finalizer from the
   operator CRs first, or restart the operator before deleting.
3. `kubectl -n tigera-operator delete pod --all`
4. Re-run the bootstrap script, which now installs Calico cleanly.
