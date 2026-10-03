# ---------------------------------------------------------------------------
# Platform bootstrap (Phase 6)
# ---------------------------------------------------------------------------
# Terraform cannot reach the cluster. The API server has no public address, the
# nodes have no public IPs, and adding a bastion or a NAT-backed runner path would
# undo the security baseline built in Phase 3. So the cluster is configured FROM
# the cluster, over SSM Run Command on the control plane.
#
# The pieces:
#
#   aws_ssm_document   the install script, pinned in Terraform so a change to it
#                      is a reviewable diff rather than something typed into a
#                      console by hand.
#   aws_ssm_association  applies that document to the control plane on a schedule,
#                      so a rebuilt or restored control plane converges by itself.
#   aws_ssm_parameter   the parameters the script reads back and the values it
#                      writes (progress state, the Argo CD admin password).
#
# Deliberately absent: the kubernetes and helm providers. Either one would need
# network reachability this design does not have, and adding it for the sake of
# two `kubectl apply` calls would trade a working security boundary for
# convenience.

locals {
  name_prefix = "${var.project}-${var.env}"

  naming_resources = {
    bootstrap_document = "platform-bootstrap-doc"
    association        = "platform-bootstrap-assoc"
    policy             = "platform-bootstrap-inst"
  }

  state_ssm     = "${var.ssm_path_prefix}/platform-bootstrap-output"
  argocd_pw_ssm = "${var.ssm_path_prefix}/argocd-admin-password"
  repo_key_ssm  = "${var.ssm_path_prefix}/argocd-repo-deploy-key"

  script = templatefile("${path.module}/templates/bootstrap-platform.sh.tftpl", {
    region                 = var.aws_region
    state_ssm              = local.state_ssm
    argocd_password_ssm    = local.argocd_pw_ssm
    argocd_repo_key_ssm    = local.repo_key_ssm
    calico_version         = var.calico_version
    helm_version           = var.helm_version
    helm_sha256            = var.helm_sha256
    argocd_chart_version   = var.argocd_chart_version
    cluster_name           = var.cluster_name
    gitops_ssh_host        = var.gitops_ssh_host
    gitops_repo_url        = var.gitops_repo_url
    gitops_repo_path       = var.gitops_repo_path
    gitops_target_revision = var.gitops_target_revision
    pod_cidr               = var.pod_cidr
  })
}

module "naming" {
  source = "../naming"

  for_each = local.naming_resources

  name        = each.value
  project     = var.project
  env         = var.env
  layer       = var.layer
  owner       = var.owner
  cost_center = var.cost_center
  component   = "platform"
}

locals {
  resource_tags = {
    for key, naming in module.naming : key => merge(naming.tags, var.extra_tags)
  }

  # An AWS-RunShellScript document is a managed resource that pins a default
  # version. Updating it in place would change what a scheduled run executes, so
  # each script change is a new version and older versions are kept: a run that is
  # already in flight when the version changes completes against the version it
  # started with, and rolling back is a version switch rather than a new document.
  document = {
    schemaVersion = "2.2"
    description   = "Install the ${var.project}/${var.env} platform add-ons: Calico, Argo CD and the root Application. Managed by Terraform."
    parameters    = {}
    content       = local.script
  }
}

# Stable name, content updated in place. SSM versions the document on every PUT, so
# a script change is still a reviewable Terraform diff, and rolling back is a
# version switch rather than a new document. Hashing the script into the name
# would instead leave one orphaned document per edit, and nothing in the console
# would say which one is current.
resource "aws_ssm_document" "bootstrap" {
  name          = module.naming["bootstrap_document"].full_name
  document_type = "Command"

  # mainSteps, not mainType + content.runtimeConfig.
  #
  # The documented modern shape for an AWS-RunShellScript document is
  #   {"schemaVersion":"2.2","mainType":"AWS-RunShellScript","content":{"runtimeConfig":...}}
  # and this endpoint rejects every version of it:
  #   InvalidDocumentContent: Unknown property "content"
  #   InvalidDocumentContent: Unknown property "runtimeConfig"
  #   InvalidDocumentContent: Unknown property "mainType"
  # What it accepts is the legacy shape - a mainSteps array - under any schema
  # version from 2.0 up, so 2.2 is kept for consistency with the rest of the repo.
  # Verified against ap-south-1 by creating documents of each shape.
  #
  # Note the script must be passed as a single runCommand entry. Splitting it into
  # one entry per line would give every line its own shell and its own exit code,
  # so `set -e` would only ever apply within a line.
  content = jsonencode({
    schemaVersion = local.document.schemaVersion
    description   = local.document.description
    parameters    = local.document.parameters
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "bootstrapPlatform"
        inputs = {
          runCommand = [local.script]
        }
      }
    ]
  })

  tags = local.resource_tags["bootstrap_document"]
}

# ---------------------------------------------------------------------------
# Association
# ---------------------------------------------------------------------------
# apply_only_at_cron_interval is off on purpose: the point is that a control plane
# rebuilt by hand converges on its own, and skipping the first run "because it is
# too soon" would leave it unconfigured until the next window opens.
resource "aws_ssm_association" "bootstrap" {
  # association_name is the association's own name; name is the DOCUMENT it runs.
  # The attribute names are easy to swap, and swapping them produces an
  # association named after a document that does not exist.
  association_name = module.naming["association"].full_name
  name             = aws_ssm_document.bootstrap.name
  document_version = aws_ssm_document.bootstrap.latest_version

  # Provider v6 made association_id computed: it is the id SSM assigns the
  # association, not the target. The target moved to a `targets` block keyed by
  # InstanceIds, and setting association_id directly now fails as an
  # unconfigurable attribute.
  targets {
    key    = "InstanceIds"
    values = [var.control_plane_instance_id]
  }

  schedule_expression              = var.association_schedule
  apply_only_at_cron_interval      = false
  wait_for_success_timeout_seconds = var.bootstrap_timeout_seconds



  # Output is not stored. The script publishes what matters - progress state and
  # the Argo CD admin password - into SSM Parameter Store under this cluster's own
  # prefix, which is readable, versioned and covered by the node role's KMS key.
  # CloudWatch would give a second, harder-to-read copy of the same thing, and
  # output_location with an empty S3 bucket is rejected by the API.

  tags = local.resource_tags["association"]
}

# ---------------------------------------------------------------------------
# Parameters the script reads and writes
# ---------------------------------------------------------------------------
# Neither the progress state nor the Argo CD admin password is created here. The
# script writes both, and a Terraform-managed empty placeholder would be readable
# as a real value - "Argo CD has no password" is a different claim from the true
# one, and it is the kind of difference that costs an afternoon.
#
# The repository deploy key is not created here either, for the same reason plus a
# practical one: putting the key in Terraform would put it in state, in the S3
# backend and in every plan, which is exactly what the SecureString is for. Create
# it out of band when the repository is private:
#
#   aws ssm put-parameter --name /dpx/prod/k8s/argocd-repo-deploy-key \
#     --type SecureString --key-id <ssm kms key id> --value "$(cat deploy_key)"
#
# The script treats the parameter's absence as "repository is public", which is
# the right default: a missing key must not be an error, or every public-repo
# deployment would need one created first.

