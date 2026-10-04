#!/usr/bin/env bash
#
# down.sh - pause an environment without destroying anything.
#
# This is the same operation as `compute_enabled = false` in 10-network and
# 30-cluster, applied directly through the EC2 API:
#
#   * NAT and control plane are STOPPED IN PLACE. Not terminated. The control plane's
#     root volume keeps etcd, so all cluster state - every Secret, every ConfigMap,
#     every custom resource - is still there when it starts again.
#   * The worker ASG is set to desired capacity 0. Its instances are terminated,
#     which is fine: they hold no state, and the replacement worker joins from the
#     SSM-published kubeadm token like any new node.
#
# What survives, and what it costs while paused (roughly USD 3/month):
#
#   EBS gp3 root volumes   ~USD 2.40   delete_on_termination only fires on termination
#   ALB                    ~USD 0.02/h left running on purpose: destroying it loses
#                                    the target group wiring in 30-cluster
#   S3 buckets, KMS keys, state          negligible
#
# Usage:
#   ./scripts/down.sh <env>              # stop instances, scale the ASG to 0
#   ./scripts/down.sh <env> --dry-run    # print what would happen
#   ./scripts/down.sh <env> --skip-asg   # instances only; leave workers running
#
# Requires: aws CLI v2 and ec2:StopInstances + autoscaling:UpdateDesiredCapacity.
#           On Windows, run from Git Bash or WSL.

set -euo pipefail

ENVIRONMENT="${1:-}"
MODE="${2:-}"

usage() {
    sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

case "$MODE" in
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
DRY_RUN=false
SKIP_ASG=false

case "$MODE" in
    --dry-run) DRY_RUN=true ;;
    --skip-asg) SKIP_ASG=true ;;
    "") ;;
    *)
        echo "error: unknown option '$MODE'" >&2
        usage 1
        ;;
esac

run() {
    if [ "$DRY_RUN" = true ]; then
        echo "  [dry-run] $*"
    else
        "$@"
    fi
}

echo "==> environment: $ENVIRONMENT   region: $REGION${DRY_RUN:+   (dry run)}"

# ---------------------------------------------------------------------------
# Inventory
# ---------------------------------------------------------------------------
# Instances are found by tag rather than from Terraform state, so this works when the
# local state is stale or absent - which it is on a fresh checkout, and it is exactly
# the situation where someone reaches for a script instead of re-planning.
#
# The two lookups are separate on purpose. The control plane carries Role=control-plane;
# the NAT does not, because fck-nat was written before that tag existed, so it is
# matched on its Name. Matching both by Name would break the moment an instance is
# renamed, and matching the control plane by "not a NAT" would break the day the
# cluster grows a second non-NAT instance.

mapfile -t CONTROL_PLANES < <(aws ec2 describe-instances \
    --region "$REGION" \
    --filters \
    "Name=tag:Project,Values=dpx" \
    "Name=tag:Env,Values=$ENVIRONMENT" \
    "Name=tag:Role,Values=control-plane" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text | tr '\t' '\n' | grep -v '^None$' || true)

mapfile -t NATS < <(aws ec2 describe-instances \
    --region "$REGION" \
    --filters \
    "Name=tag:Project,Values=dpx" \
    "Name=tag:Env,Values=$ENVIRONMENT" \
    --filters "Name=tag:Name,Values=*nat*" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text | tr '\t' '\n' | grep -v '^None$' || true)

TARGETS=("${CONTROL_PLANES[@]}" "${NATS[@]}")

if [ "${#TARGETS[@]}" -eq 0 ]; then
    echo "nothing to stop: no control plane or NAT found for $ENVIRONMENT"
    exit 0
fi

# ---------------------------------------------------------------------------
# Scale the ASG first
# ---------------------------------------------------------------------------
# Before stopping the control plane, not after. A group with a minimum above 0 whose
# control plane has just gone away will spend the next few minutes relaunching
# workers that cannot join, and each attempt is a round trip to an API server that is
# shutting down - which is how a graceful stop turns into a timeout.
#
# The group's current minimum is left alone. Terraform owns that number; this script
# only sets desired capacity, so a later apply reconciles without a fight.

ASG_NAME="$(aws autoscaling describe-auto-scaling-groups \
    --region "$REGION" \
    --query "AutoScalingGroups[?length(Tags[?Key=='Env' && Value=='$ENVIRONMENT']) > `0`].AutoScalingGroupName | [0]" \
    --output text 2>/dev/null || echo "None")"

if [ "$SKIP_ASG" = true ]; then
    echo "==> worker ASG: skipped (--skip-asg)"
elif [ "$ASG_NAME" = "None" ] || [ -z "$ASG_NAME" ]; then
    echo "==> worker ASG: not found (30-cluster may not be applied)"
else
    echo "==> worker ASG: $ASG_NAME -> desired capacity 0"
    run aws autoscaling update-desired-capacity \
        --region "$REGION" \
        --auto-scaling-group-name "$ASG_NAME" \
        --desired-capacity 0
fi

# ---------------------------------------------------------------------------
# Stop the instances
# ---------------------------------------------------------------------------
# NAT before control plane: the reverse of up.sh. Every node in the cluster, including
# the control plane, has a default route through the NAT, so a control plane still
# trying to reach the internet during shutdown produces cloud-init failures and
# eventually times out. Taking the NAT away first makes those failures immediate and
# obvious instead of slow and confusing.

echo "==> stopping instances"
for id in "${NATS[@]:-}"; do
    [ -z "$id" ] && continue
    echo "    NAT $id"
    run aws ec2 stop-instances --region "$REGION" --instance-ids "$id"
done

for id in "${CONTROL_PLANES[@]:-}"; do
    [ -z "$id" ] && continue
    echo "    control plane $id"
    run aws ec2 stop-instances --region "$REGION" --instance-ids "$id"
done

cat <<EOF

==> next: Terraform does not know about this yet

These instances are stopped behind Terraform's back. compute_enabled is still true in
infra/envs/$ENVIRONMENT/10-network and infra/envs/$ENVIRONMENT/30-cluster, so the next
apply in either layer will start them again. Flip both to false and apply:

  sed -i 's/^compute_enabled = true/compute_enabled = false/' \\
      infra/envs/$ENVIRONMENT/10-network/$ENVIRONMENT.tfvars \\
      infra/envs/$ENVIRONMENT/30-cluster/$ENVIRONMENT.tfvars

  ( cd infra/envs/$ENVIRONMENT/10-network && terraform apply -input=false \\
      "-var-file=../common.tfvars" "-var-file=$ENVIRONMENT.tfvars" )
  ( cd infra/envs/$ENVIRONMENT/30-cluster && terraform apply -input=false \\
      "-var-file=../common.tfvars" "-var-file=$ENVIRONMENT.tfvars" )

==> to resume

  ./scripts/up.sh $ENVIRONMENT

==> one thing that does NOT survive

The SSM join token has a TTL. The control plane's timer regenerates it every ~30
minutes, but a control plane stopped for a week has an expired token, and the worker
ASG will relaunch into a cluster it cannot join. up.sh does not need to handle that -
the timer starts first and republishes before the worker ASG scales out - but if a
worker ever fails to join after a long pause, check the timer before anything else:

  aws ssm send-command --region $REGION --instance-ids <control-plane-id> \\
      --document-name AWS-RunShellScript \\
      --parameters 'commands=["systemctl status k8s-join-token.timer --no-pager"]'
EOF
