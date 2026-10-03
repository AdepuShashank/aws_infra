output "layer" {
  description = "Layer name."
  value       = module.foundation.layer
}

output "env" {
  description = "Environment name."
  value       = module.foundation.env
}

output "name_prefix" {
  description = "Resource name prefix (project-env)."
  value       = module.foundation.name_prefix
}

output "standard_tags" {
  description = "Standard tag map applied to every resource in this layer."
  value       = module.foundation.standard_tags
}

output "aws_account_id" {
  description = "AWS account id resolved via STS."
  value       = module.foundation.aws_account_id
}
# ---------------------------------------------------------------------------
# Platform bootstrap
# ---------------------------------------------------------------------------
output "ssm_document_name" {
  description = "Name of the SSM document holding the platform bootstrap script. Pass it to `aws ssm send-command` to run the bootstrap by hand."
  value       = module.platform.ssm_document_name
}

output "ssm_document_version" {
  description = "Latest version of the bootstrap document. Changing the script produces a new version."
  value       = module.platform.ssm_document_version
}

output "association_id" {
  description = "SSM association applying the bootstrap document to the control plane."
  value       = module.platform.association_id
}

output "progress_state_parameter" {
  description = "Parameter the bootstrap script writes its progress to. Read this first when a run fails."
  value       = module.platform.progress_state_parameter
}

output "argocd_admin_password_parameter" {
  description = "SecureString parameter holding the Argo CD initial admin password."
  value       = module.platform.argocd_admin_password_parameter
}

output "argocd_repo_deploy_key_parameter" {
  description = "SecureString parameter the script reads a repository deploy key from."
  value       = module.platform.argocd_repo_deploy_key_parameter
}

output "access_instructions" {
  description = "How to reach Argo CD, which is ClusterIP-only and deliberately not exposed."
  value       = module.platform.access_instructions
}

output "platform_versions" {
  description = "Versions this layer pins, for comparison against docs/versions.md and the running cluster."
  value       = module.platform.platform_versions
}

output "cluster_facts" {
  description = "Cluster values read from 30-cluster state, so a reader can confirm the Calico IP pool matches what kubeadm was given."
  value = {
    cluster_name              = local.cluster_name
    pod_cidr                  = local.pod_cidr
    control_plane_instance_id = local.control_plane_instance_id
    control_plane_private_ip  = local.control_plane_ip
  }
}