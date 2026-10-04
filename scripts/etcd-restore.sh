#!/usr/bin/env bash
#
# etcd-restore.sh - list, verify and (with confirmation) restore an etcd snapshot.
#
# This is the script half of docs/etcd-restore.md. The document is the runbook and
# explains what each step is for; this does the mechanical parts so that a restore at
# 2am does not depend on remembering argument order.
#
# What a restore actually is, so the guard rails below make sense: replacing the
# contents of etcd on the control plane. Every Secret, ConfigMap, Deployment,
# Application and CR in the cluster lives in that one database. Restoring a snapshot
# from yesterday means the cluster comes back exactly as it was yesterday, which
# includes any Secret that was rotated since - and that is the reason this is a
# deliberate two-person action and not a script anyone runs reflexively.
#
# There is no automatic restore. There is an alarm when backups go stale
# (dpx-<env>-etcd-snapshot-stale) and this script.
#
# Usage:
#   ./scripts/etcd-restore.sh <env> list
#   ./scripts/etcd-restore.sh <env> verify [<snapshot-key>]
#   ./scripts/etcd-restore.sh <env> restore <snapshot-key>   # asks, then does it
#   ./scripts/etcd-restore.sh <env> download <snapshot-key> [outfile]
#
# Requires: aws CLI v2 with s3 access to the backup bucket and ec2:StopInstances /
#           ec2:StartInstances. On Windows, run from Git Bash or WSL.

set -euo pipefail

ENVIRONMENT="${1:-}"
ACTION="${2:-}"
ARGUMENT="${3:-}"

usage() {
    sed -n '2,24p' "$0" | sed 's/^## \{0,1\}//'
    exit "${1:-0}"
}

case "$ACTION" in
    -h | --help) usage 0 ;;
esac

if [ -z "$ENVIRONMENT" ] || [ -z "$ACTION" ]; then
    usage 1
fi

case "$ENVIRONMENT" in
    prod | qa) ;;
    *)
        echo "error: env must be prod or qa, got '$ENVIRONMENT'" >&2
        exit 1
        ;;
esac

REGION="${AWS_REGION:-ap-south-1}"
PROJECT="${PROJECT:-dpx}"
BUCKET="$PROJECT-$ENVIRONMENT-etcd-backups"

# ---------------------------------------------------------------------------
# Locate the control plane
# ---------------------------------------------------------------------------
# Resolved from the EC2 API by tag, not from Terraform state: a restore is exactly the
# moment where the local state is least likely to be telling the truth, because the
# thing you are restoring is the thing the state was written from.

CONTROL_PLANE="$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters \
    "Name=tag:Project,Values=$PROJECT" \
    "Name=tag:Env,Values=$ENVIRONMENT" \
    "Name=tag:Role,Values=control-plane" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text)"

if [ "$CONTROL_PLANE" = "None" ] || [ -z "$CONTROL_PLANE" ]; then
    echo "error: no control plane found for $ENVIRONMENT in $REGION." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# ssm - run a script on the control plane and return its stdout
# ---------------------------------------------------------------------------
# SSM rather than SSH because there is no SSH, and rather than kubectl exec because
# the exec streaming path to the kubelet is broken on this cluster ("tls: internal
# error"). `aws ssm get-command-invocation` is the one output path that works.
#
# The --max-items 1 on list-command-invocations is not optional. Without it the
# command id captures every past invocation, and the next aws call fails with
# "Unknown options".
ssm() {
    local script="$1"
    local command_id status output

    command_id="$(aws ssm send-command \
        --region "$REGION" \
        --instance-ids "$CONTROL_PLANE" \
        --document-name AWS-RunShellScript \
        --parameters "commands=[\"$script\"]" \
        --query "Command.CommandId" --output text)"

    if [ -z "$command_id" ] || [ "$command_id" = "None" ]; then
        echo "error: SSM refused the command. Is the control plane running?" >&2
        exit 1
    fi

    # SSM serialises commands per instance, so a command stuck in Pending blocks
    # every later one. Waiting on this specific id, rather than issuing the next
    # request and hoping, is what keeps a stuck command from swallowing the rest.
    status="Pending"
    for _ in $(seq 1 60); do
        status="$(aws ssm list-command-invocations \
            --region "$REGION" \
            --instance-id "$CONTROL_PLANE" \
            --command-id "$command_id" \
            --max-items 1 \
            --query "CommandInvocations[0].Status" --output text 2>/dev/null || echo Pending)"
        [ "$status" = "Success" ] || [ "$status" = "Failed" ] || [ "$status" = "Cancelled" ] && break
        sleep 5
    done

    output="$(aws ssm get-command-invocation \
        --region "$REGION" \
        --instance-id "$CONTROL_PLANE" \
        --command-id "$command_id" \
        --query "[StandardOutputContent,StandardErrorContent]" \
        --output text 2>/dev/null || true)"

    printf '%s\n' "$output"

    [ "$status" = "Success" ] || {
        echo "error: the SSM command finished with status $status" >&2
        return 1
    }
}

# ---------------------------------------------------------------------------
# list
# ---------------------------------------------------------------------------
if [ "$ACTION" = "list" ]; then
    echo "==> snapshots in s3://$BUCKET (newest last)"
    aws s3api list-objects-v2 \
        --region "$REGION" \
        --bucket "$BUCKET" \
        --prefix "etcd-" \
        --query "reverse(sort_by(Contents || \`[]\`, &LastModified))[].{key:Key,size:Size,modified:LastModified}" \
        --output table
    exit 0
fi

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------
# The only check that matters before a restore: does this file actually contain a
# restorable etcd snapshot. A truncated or empty .db file uploads fine and restores as
# a corrupt member, and etcdctl snapshot restore reports the corruption only after it
# has already consumed the file.
#
# `etcdutl snapshot status` is the right tool; `etcdctl snapshot status` is deprecated
# for it. Both are installed on the control plane by cloud-init.
if [ "$ACTION" = "verify" ]; then
    KEY="${ARGUMENT:-$(aws s3api list-objects-v2 \
        --region "$REGION" --bucket "$BUCKET" --prefix "etcd-" \
        --query "sort_by(Contents || \`[]\`, &LastModified)[-1].Key" --output text)}"

    echo "==> verifying $KEY"
    ssm "aws s3 cp 's3://$BUCKET/$KEY' /tmp/verify-snapshot.db --region $REGION --quiet \
        && ls -l /tmp/verify-snapshot.db \
        && etcdutl snapshot status /tmp/verify-snapshot.db -w table \
        ; rm -f /tmp/verify-snapshot.db"
    exit 0
fi

# ---------------------------------------------------------------------------
# download
# ---------------------------------------------------------------------------
if [ "$ACTION" = "download" ]; then
    if [ -z "$ARGUMENT" ]; then
        echo "error: download needs a snapshot key." >&2
        echo "       List them with: $0 $ENVIRONMENT list" >&2
        exit 1
    fi
    # The output path is the fourth positional. Absent means a file named after the
    # snapshot, which is what you want nine times out of ten.
    OUT="${4:-./etcd-snapshot.db}"
    echo "==> downloading $ARGUMENT to $OUT"
    aws s3 cp "s3://$BUCKET/$ARGUMENT" "$OUT" --region "$REGION" || exit 1
    echo "==> verify it before trusting it:"
    echo "    etcdutl snapshot status $OUT -w table"
    exit 0
fi

# ---------------------------------------------------------------------------
# restore
# ---------------------------------------------------------------------------
# Everything below this line replaces cluster state.
if [ "$ACTION" != "restore" ]; then
    echo "error: unknown action '$ACTION'" >&2
    usage 1
fi

KEY="$ARGUMENT"

if [ -z "$KEY" ]; then
    echo "error: restore needs a snapshot key." >&2
    echo "       List them with: $0 $ENVIRONMENT list" >&2
    exit 1
fi

cat <<EOF

################################################################################
# THIS REPLACES EVERY OBJECT IN THE $ENVIRONMENT CLUSTER.
#
# Restoring $KEY means the cluster returns to its state at the moment that snapshot
# was taken. Anything created or changed since is gone, and that includes:
#
#   * Secrets rotated since the snapshot - the restore reinstates the old values,
#     so a credential rotated to respond to an incident comes back.
#   * The kubeadm join token - workers that have joined since will fail to rejoin
#     after the control plane comes back. This is handled below.
#   * Terraform state is NOT touched. 30-cluster's state still describes the
#     instances that exist now, not the ones that existed then.
#
# Take a snapshot of the CURRENT state first. That is the only way this is reversible.
################################################################################

EOF

read -r -p "Control plane: $CONTROL_PLANE
Bucket:         s3://$BUCKET
Snapshot:       $KEY

Type 'restore' (lower case) to continue: " CONFIRM

if [ "$CONFIRM" != "restore" ]; then
    echo "aborted"
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 1: a snapshot of the state we are about to throw away
# ---------------------------------------------------------------------------
# Named with the current time rather than "pre-restore", because two restores in one
# day is not a hypothetical and overwriting the first one makes it unrecoverable.
PRE_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

echo
echo "==> step 1/6: snapshotting current state as pre-restore-$PRE_STAMP.db"

ssm "/usr/local/bin/k8s-etcd-snapshot"

# The script deletes its local copy on success and only leaves the S3 object, so
# there is nothing to clean up. If it failed, stop here: the restore would have no
# way back.

echo
echo "==> step 2/6: stopping etcd on the control plane"

# Not the kubelet and not the whole instance. Stopping kubelet would make the
# instance NotReady and start the node-monitor evicting the control plane pod, and
# stopping the instance would mean a cold etcd start path. Stopping etcd alone leaves
# the API server up and failing fast, which is the honest state to be in while
# replacing its database.
ssm "systemctl stop etcd && sleep 5 && systemctl is-active etcd || true"

echo
echo "==> step 3/6: downloading $KEY and checking it restores to a scratch member"

# Restored into /var/lib/etcd-restore-check rather than straight into /var/lib/etcd.
# `snapshot restore` writes a whole member directory including a fresh member ID, and
# doing that directly over the live data directory is how a restore turns a bad
# afternoon into an unrecoverable one.
ssm "set -e
rm -rf /var/lib/etcd-restore-check /tmp/restore-snapshot.db
aws s3 cp 's3://$BUCKET/$KEY' /tmp/restore-snapshot.db --region $REGION --quiet
etcdutl snapshot restore /tmp/restore-snapshot.db --data-dir /var/lib/etcd-restore-check
echo '--- scratch restore OK ---'
ls /var/lib/etcd-restore-check/member"

echo
echo "==> step 4/6: moving the current data directory aside"

# Renamed, not deleted. The rename is instant and reversible; a delete is neither, and
# step 1's snapshot is a backup of the DATA while this is a backup of the exact
# directory with its permissions and file ownership intact.
ssm "set -e
rm -rf /var/lib/etcd-pre-restore
mv /var/lib/etcd /var/lib/etcd-pre-restore
echo 'moved /var/lib/etcd to /var/lib/etcd-pre-restore'"

echo
echo "==> step 5/6: restoring into /var/lib/etcd"

ssm "set -e
etcdutl snapshot restore /tmp/restore-snapshot.db --data-dir /var/lib/etcd
chown -R root:root /var/lib/etcd
chmod 700 /var/lib/etcd
rm -f /tmp/restore-snapshot.db
systemctl start etcd
sleep 10
systemctl is-active etcd"

echo
echo "==> step 6/6: checking the API server"

# kube-apiserver's static pod may still be running against a dead etcd, so give it a
# moment to notice and restart. The check that matters is /readyz, not "is etcd up":
# etcd can be running and still not be the etcd holding this cluster's data.
ssm "sleep 20
kubectl get --raw='/readyz?verbose' | tail -3
echo '--- nodes ---'
kubectl get nodes
echo '--- argocd ---'
kubectl -n argocd get applications 2>/dev/null || true"

cat <<EOF

==> done. Read this before doing anything else.

The cluster is now at the state of $KEY. Argo CD will start re-syncing from the
repository, which means any change made to the repository since the snapshot will be
re-applied - and any change made directly in the cluster since will be reverted. That
asymmetry is worth knowing about before you start fixing things by hand.

Three follow-ups, in this order:

  1. The join token is from the snapshot. The control plane's token timer
     regenerates it within ~30 minutes, but any worker that has since joined will not
     rejoin until then. Force it rather than waiting:

       ./scripts/kubeconfig-via-ssm.sh $ENVIRONMENT > /tmp/kc
       KUBECONFIG=/tmp/kc kubectl delete node <worker>

     and let the ASG replace it.

  2. Restore the control plane's ROOT VOLUME backup too, if you have one. etcd's data
     directory is not the only cluster state on that instance - the kubeadm PKI under
     /etc/kubernetes/pki is, and the snapshot does not contain it. A restored etcd
     with a different CA presents certificates the restored data never knew about.
     In this project both usually come from the same instance and the same backup
     window, so they should agree - verify rather than assume:

       ./scripts/up.sh $ENVIRONMENT
       kubectl get nodes

  3. Terraform state is now describing a cluster that came from the past. Do NOT run
     terraform apply in 30-cluster to "fix things". Read first:

       ( cd infra/envs/$ENVIRONMENT/30-cluster && terraform plan )

     A plan that wants to recreate instances here means the instance ids in state no
     longer match reality, which is a question for a human, not for -auto-approve.

Rollback, if this was the wrong call:

  ssm "systemctl stop etcd && rm -rf /var/lib/etcd && mv /var/lib/etcd-pre-restore /var/lib/etcd && systemctl start etcd"

or from the pre-restore snapshot this script took in step 1:

  ./scripts/etcd-restore.sh $ENVIRONMENT verify pre-restore-$PRE_STAMP.db
EOF
