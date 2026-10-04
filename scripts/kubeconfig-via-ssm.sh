#!/usr/bin/env bash
#
# kubeconfig-via-ssm.sh - fetch the admin kubeconfig out of SSM Parameter Store.
#
# There is no bastion and no SSH, by design, and the API server has no public
# address. The admin kubeconfig is written to a SecureString parameter by the
# control plane's cloud-init, scoped by the IAM policy in 20-security so that only a
# principal holding that parameter's KMS key can read it.
#
# This script reads it and writes it to a file. It does not modify the file beyond
# the server address, because that address is already correct: the kubeconfig points
# at the fixed private IP on the control plane's dedicated ENI (10.10.10.10 for
# prod), which is routable from wherever you run this and is why that IP is reserved
# rather than left to DHCP.
#
# Usage:
#   ./scripts/kubeconfig-via-ssm.sh <env>              # write to ./kubeconfig-<env>
#   ./scripts/kubeconfig-via-ssm.sh <env> <outfile>    # write somewhere specific
#   ./scripts/kubeconfig-via-ssm.sh <env> --print      # to stdout, nothing written
#   ./scripts/kubeconfig-via-ssm.sh <env> --show-endpoint
#
# Requires: aws CLI v2, ssm:GetParameter on /<project>/<env>/k8s/admin-kubeconfig,
#           and kms:Decrypt on alias/<project>-<env>-kms-ssm.
#           On Windows, run from Git Bash or WSL.

set -euo pipefail

ENVIRONMENT="${1:-}"
DEST="${2:-}"

usage() {
    sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

case "${DEST:-}" in
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
PROJECT="${PROJECT:-dpx}"
PARAMETER="/$PROJECT/$ENVIRONMENT/k8s/admin-kubeconfig"
PRINT_ONLY=false
SHOW_ENDPOINT=false

case "$DEST" in
    --print) PRINT_ONLY=true ;;
    --show-endpoint) SHOW_ENDPOINT=true ;;
    "") DEST="./kubeconfig-$ENVIRONMENT" ;;
esac

# ---------------------------------------------------------------------------
# Read
# ---------------------------------------------------------------------------
# --with-decryption is not optional and the failure without it is a good one:
# Parameter Store returns the base64 of the ciphertext, which decodes into
# something that is not YAML, and the error surfaces later as a confusing parse
# failure rather than as a permissions problem.
echo "==> reading $PARAMETER" >&2

if ! RAW="$(aws ssm get-parameter \
    --region "$REGION" \
    --name "$PARAMETER" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text 2>&1)"; then
    echo "error: could not read $PARAMETER" >&2
    echo "$RAW" >&2
    echo >&2
    case "$RAW" in
        *"is not authorized"* | *"AccessDenied"*)
            echo "Your principal is missing ssm:GetParameter on $PARAMETER," >&2
            echo "or kms:Decrypt on alias/$PROJECT-$ENVIRONMENT-kms-ssm." >&2
            echo "Both are granted by 20-security to the node role, not to you." >&2
            echo "If you have not been granted the parameter explicitly, read it" >&2
            echo "through an SSM session on the control plane instead - see below." >&2
            ;;
        *"ParameterNotFound"*)
            echo "The parameter does not exist, which means the control plane has" >&2
            echo "never finished bootstrapping. Check:" >&2
            echo "  aws ssm get-parameter --region $REGION \\" >&2
            echo "    --name /$PROJECT/$ENVIRONMENT/k8s/bootstrap-output --query Parameter.Value --output text" >&2
            ;;
    esac
    exit 1
fi

# ---------------------------------------------------------------------------
# Decode
# ---------------------------------------------------------------------------
# The control plane stores it base64-encoded, so this is two layers, and getting the
# order wrong produces YAML that is almost right: base64 of YAML is valid base64, and
# a double-decode failure looks like a malformed kubeconfig rather than an encoding
# mistake.
KUBECONFIG="$(printf '%s' "$RAW" | base64 --decode)" || {
    echo "error: the parameter's value is not valid base64." >&2
    echo "       Expected: the base64 of a kubeconfig YAML document." >&2
    exit 1
}

# A decoded value that is not a kubeconfig means the double-decode above, or a
# parameter written by something other than the bootstrap. Either way, saying so is
# more useful than handing kubectl a file it will reject.
if ! printf '%s' "$KUBECONFIG" | grep -q "apiVersion:"; then
    echo "error: the decoded value is not a kubeconfig." >&2
    echo "       First bytes: $(printf '%s' "$KUBECONFIG" | head -c 80)" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
ENDPOINT="$(printf '%s' "$KUBECONFIG" | grep -o 'https://[0-9a-zA-Z.:-]*' | head -1)"

echo "==> server: ${ENDPOINT:-unknown}" >&2

if [ "$SHOW_ENDPOINT" = true ]; then
    printf '%s\n' "$ENDPOINT"
    exit 0
fi

# ---------------------------------------------------------------------------
# Write
# ---------------------------------------------------------------------------
if [ "$PRINT_ONLY" = true ]; then
    printf '%s\n' "$KUBECONFIG"
    exit 0
fi

umask 077
printf '%s\n' "$KUBECONFIG" > "$DEST"
chmod 0600 "$DEST"

cat >&2 <<EOF

==> wrote $DEST (mode 600)

  export KUBECONFIG="\$(pwd)/$DEST"
  kubectl get nodes

Two things to expect:

  * The server is a private IP inside the VPC. From a workstation that is not on the
    VPN this connection will hang, and that is not a kubeconfig problem - it is the
    Phase 3 security baseline working. Use an SSM session instead:

        aws ssm start-session --target-id <control-plane-id>

    and run kubectl from inside that session.

  * \`kubectl exec\` and \`kubectl logs\` do not work against this cluster: the apiserver
    reports "remote error: tls: internal error" on the streaming path to the kubelet.
    \`kubectl get\`, \`describe\`, \`patch\` and pod events all work. For anything that needs
    stdout, use aws ssm get-command-invocation.

Never commit this file. It contains a client certificate with cluster-admin.
EOF

exit 0
