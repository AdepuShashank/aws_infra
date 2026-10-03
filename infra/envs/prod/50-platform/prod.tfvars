# Phase 6 (50-platform) settings for prod.
#
# Applied with:
#   terraform plan -input=false "-var-file=..\common.tfvars" "-var-file=prod.tfvars"

# Same bucket 30-cluster and every other layer in this environment use.
state_bucket = "dpx-tfstate-prod"

# Calico v3.32.2. Not the newest release: Calico tests against a specific set of
# Kubernetes minors and this cluster runs 1.36, which v3.32 is tested for. See
# docs/versions.md.
calico_version = "v3.32.2"

# Helm is installed by the bootstrap script rather than in the node bootstrap,
# because Phase 6 is the first thing that needs it. The sha256 pins the download
# to this exact linux-arm64 artifact; the script re-verifies it against the
# published checksum before installing, so the URL being hijacked is not enough.
helm_version = "3.20.0"
helm_sha256  = "bfb14953295d5324d47ab55f3dfba6da28d46c848978c8fbf412d4271bdc29f1"

# argo-cd chart 10.9.6 ships Argo CD v3.5.3.
argocd_chart_version = "10.9.6"

# ---------------------------------------------------------------- GitOps ---
# TODO: replace with the real repository before the first apply. The bootstrap
# script creates the root Application pointing here, so a wrong value produces an
# Application stuck OutOfSync against a repository that does not exist - visible,
# but only after the association has run.
gitops_repo_url        = "AdepuShashank/aws_infra"
gitops_repo_path       = "gitops/prod"
gitops_target_revision = "main"
gitops_ssh_host        = "github.com"

# Every 30 minutes. The platform is installed once and then left to Argo CD, so
# this is not about reinstalling anything: it is so a control plane replaced by
# hand, or restored from an etcd snapshot, converges without anyone remembering
# to run the bootstrap again.
association_schedule = "rate(30 minutes)"
