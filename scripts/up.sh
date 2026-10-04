#!/usr/bin/env bash
#
# up.sh - bring an environment back from a paused state.
#
# "Paused" means compute_enabled = false in 10-network and 30-cluster, applied. The
# NAT and control plane are stopped in place and the worker ASG is at zero. Nothing
# was destroyed: the control plane's root volume still holds etcd, so the cluster
# state comes back with the instance.
#
# What this script does NOT do, deliberately:
#
#   * It does not run `terraform apply`. compute_enabled is a Terraform variable, so
#     flipping it is an apply, and an apply is a decision with a state lock and a
#     plan attached. This script performs the AWS-side half only, which is safe to
#     re-run and needs no state.
#   * It does not touch the worker ASG. The ASG relaunches its own workers on demand
#     once the cluster is reachable, and setting desired capacity by hand is how a
#     worker ends up trying to join a control plane that is still booting.
#
# Then: edit the two tfvars files (see the banner this prints), apply them, and run
# this script again with --start-only if the instances are already running.
#
# Usage:
#   ./scripts/up.sh <env>              # start instances, then print what to apply
#   ./scripts/up.sh <env> --start-only # start instances and do nothing else
#   ./scripts/up.sh <env> --wait      # also block until the API server answers
#
# Requires: aws CLI v2, credentials from SSO or an environment that can call STS,
#           and permission to start EC2 instances. On Windows, run this from Git Bash
#           or WSL - it is bash, not PowerShell.

set -euo pipefail

ENVIRONMENT="${1:-}"
MODE="${2:-}"

usage() {
    sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

case "${MODE:-}" in
    -h | --help) usage 0 ;;
esac

if [ -z "$ENVIRONMENT" ]; then
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

# Layers are addressed by directory, because that is what Terraform calls them.
LAYER_CLUSTER="infra/envs/$ENVIRONMENT/30-cluster"

echo "==> environment: $ENVIRONMENT   region: $REGION"

# ---------------------------------------------------------------------------
# 1. Control plane first
# ---------------------------------------------------------------------------
# The control plane before the NAT, even though the NAT is what the control plane
# needs for egress. The order is not about networking: kubeadm on a worker reads the
# join command from SSM and needs the API server, and the API server's cloud-init
# needs egress for the Calico manifests. Starting the control plane first and giving
# it two minutes means that when the worker ASG launches into the cluster, both the
# control plane and its egress path already exist.
#
# The instance id is read from the ASG's own tag rather than from Terraform state, so
# this script works even when the local state is stale - which is exactly the case
# after a control-plane replacement nobody has re-applied for.

control_plane_id="$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters \
    "Name=tag:Project,Values=dpx" \
    "Name=tag:Env,Values=$ENVIRONMENT" \
    "Name=tag:Role,Values=control-plane" \
    "Name=instance-state-name,Values=running,stopped,stopping,pending" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text)"

if [ "$control_plane_id" = "None" ] || [ -z "$control_plane_id" ]; then
    echo "error: no control plane found for $ENVIRONMENT." >&2
    echo "       Either 30-cluster has never been applied, or the instance is" >&2
    echo "       terminated - check with:" >&2
    echo "         aws ec2 describe-instances --region $REGION --filters Name=tag:Project,Values=dpx Name=tag:Env,Values=$ENVIRONMENT" >&2
    exit 1
fi

# One NAT per environment, tagged Role absent because fck-nat predates that tag.
nat_id="$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters \
    "Name=tag:Project,Values=dpx" \
    "Name=tag:Env,Values=$ENVIRONMENT" \
    "Name=tag:instance-state-name,Values=running,stopped,stopping,pending" \
    --query "Reservations[].Instances[?contains(Name, \`nat\`)].InstanceId | [0]" \
    --output text)"

# ---------------------------------------------------------------------------
# 2. Start them
# ---------------------------------------------------------------------------
start_instance() {
    local id="$1"
    local what="$2"
    local state

    state="$(aws ec2 describe-instances --region "$REGION" \
        --instance-ids "$id" \
        --query 'Reservations[0].Instances[0].State.Name' --output text)"

    case "$state" in
        running)
            echo "    $what $id is already running"
            return 0
            ;;
        pending | stopping)
            echo "    $what $id is $state, waiting rather than issuing a conflicting request"
            ;;
        *)
            echo "    starting $what $id"
            aws ec2 start-instances --region "$REGION" --instance-ids "$id" >/dev/null
            ;;
    esac
}

echo "==> starting instances"
start_instance "$control_plane_id" "control plane"

if [ "$nat_id" != "None" ] && [ -n "$nat_id" ]; then
    start_instance "$nat_id" "NAT"
else
    echo "    NAT: not found, skipping (10-network may not be applied)"
fi

# The worker ASG stays at whatever its minimum is. At prod's minimum of 1 it will
# launch a worker on its own as soon as it can reach the API server, and that worker
# joins from the SSM-published token like any new node - which is the Phase 4
# acceptance criterion, exercised by every resume.

# ---------------------------------------------------------------------------
# 3. Terraform still has to be told
# ---------------------------------------------------------------------------
cat <<EOF

==> next: Terraform does not know about this yet

Starting an instance behind Terraform's back leaves compute_enabled = false in
$LAYER_CLUSTER and infra/envs/$ENVIRONMENT/10-network. The next apply would stop them
again. Flip both to true and apply:

  sed -i 's/^compute_enabled = false/compute_enabled = true/' \\
      infra/envs/$ENVIRONMENT/10-network/$ENVIRONMENT.tfvars \\
      $LAYER_CLUSTER/$ENVIRONMENT.tfvars

  ( cd infra/envs/$ENVIRONMENT/10-network && terraform apply -input=false \\
      "-var-file=../common.tfvars" "-var-file=$ENVIRONMENT.tfvars" )
  ( cd $LAYER_CLUSTER && terraform apply -input=false \\
      "-var-file=../common.tfvars" "-var-file=$ENVIRONMENT.tfvars" )

Quote the -var-file arguments. Unquoted, PowerShell hands Terraform a bare
"=../common.tfvars" positional and it fails with "Too many command line arguments".

==> then wait about 6 minutes and check

  # from your workstation
  ./scripts/kubeconfig-via-ssm.sh $ENVIRONMENT > ./kubeconfig-$ENVIRONMENT
  KUBECONFIG=./kubeconfig-$ENVIRONMENT kubectl get nodes

The control plane takes roughly 2 minutes to finish kubeadm init on boot and a worker
4-5 to join. The platform bootstrap association re-fires within 30 minutes and is
idempotent, so Argo CD and Calico need no manual step.
EOF

# ---------------------------------------------------------------------------
# 4. Optional: wait for the API server
# ---------------------------------------------------------------------------
if [ "$MODE" = "--wait" ]; then
    echo "==> waiting for the API server (this takes 2-4 minutes)"
    deadline=$(( $(date +%s) + 600 ))

    while [ "$(date +%s)" -lt "$deadline" ]; do
        # SSM rather than kubectl: there is no working kubeconfig on the workstation
        # yet, and the check is "is kubeadm finished", not "is the cluster healthy".
        status="$(aws ssm send-command \
            --region "$REGION" \
            --instance-ids "$control_plane_id" \
            --document-name AWS-RunShellScript \
            --parameters 'commands=["kubectl get --raw=/readyz?verbose | tail -1"]' \
            --query "Command.CommandId" --output text 2>/dev/null || echo "")"

        if [ -z "$status" ] || [ "$status" = "None" ]; then
            echo "    control plane not registered with SSM yet"
            sleep 20
            continue
        fi

        # Wait for this one command rather than the previous one: SSM serialises
        # commands per instance, so a second send-command while the first is Pending
        # queues behind it and never returns.
        for _ in $(seq 1 30); do
            result="$(aws ssm list-command-invocations \
                --region "$REGION" \
                --instance-id "$control_plane_id" \
                --command-id "$status" \
                --query "CommandInvocations[0].Status" --output text 2>/dev/null || echo "Pending")"
            [ "$result" = "Success" ] && break
            [ "$result" = "Failed" ] && break
            sleep 5
        done

        if [ "$result" = "Success" ]; then
            echo "    API server is ready"
            exit 0
        fi

        echo "    not ready yet ($result)"
        sleep 15
    done

    echo "    timed out after 10 minutes; check the SSM command output by hand:" >&2
    echo "      aws ssm get-command-invocation --region $REGION --command-id <id> --instance-id $control_plane_id" >&2
    exit 1
fi

exit 0
