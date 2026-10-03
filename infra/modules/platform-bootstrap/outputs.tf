output "ssm_document_name" {
  description = "Name of the SSM document holding the platform bootstrap script. Useful for `aws ssm send-command --document-name` when running it by hand."
  value       = aws_ssm_document.bootstrap.name
}

output "ssm_document_arn" {
  description = "ARN of the platform bootstrap document."
  value       = aws_ssm_document.bootstrap.arn
}

output "ssm_document_version" {
  description = "Latest version of the bootstrap document. Bumping the script produces a new version."
  value       = aws_ssm_document.bootstrap.latest_version
}

output "association_id" {
  description = "SSM association id applying the bootstrap document to the control plane."
  value       = aws_ssm_association.bootstrap.id
}

output "association_schedule" {
  description = "Schedule the bootstrap association runs on."
  value       = aws_ssm_association.bootstrap.schedule_expression
}

output "progress_state_parameter" {
  description = "Parameter the script writes its progress to. Read this first when the association fails: it names the stage, not just the failure."
  value       = local.state_ssm
}

output "argocd_admin_password_parameter" {
  description = "SecureString parameter holding the Argo CD initial admin password."
  value       = local.argocd_pw_ssm
}

output "argocd_repo_deploy_key_parameter" {
  description = "SecureString parameter the script reads a repository deploy key from. Populate out of band."
  value       = local.repo_key_ssm
}

output "argocd_namespace" {
  description = "Namespace Argo CD is installed into."
  value       = "argocd"
}

output "access_instructions" {
  description = "How to reach Argo CD, which is deliberately not exposed."
  value = {
    namespace          = "argocd"
    service            = "argocd-server (ClusterIP only, not exposed)"
    port_forward       = "kubectl -n argocd port-forward svc/argocd-server 8080:80"
    password_parameter = local.argocd_pw_ssm
  }
}

output "platform_versions" {
  description = "Versions this layer pins, so docs/versions.md and the running cluster can be compared."
  value = {
    calico          = var.calico_version
    helm            = var.helm_version
    argocd_chart    = var.argocd_chart_version
    gitops_revision = var.gitops_target_revision
    gitops_path     = var.gitops_repo_path
  }
}
