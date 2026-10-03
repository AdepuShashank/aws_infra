output "alb_security_group_id" {
  description = "Security group for the public ALB. 40-edge attaches this to the load balancer."
  value       = aws_security_group.alb.id
}

output "workers_security_group_id" {
  description = "Security group for worker nodes. 30-cluster attaches this to the worker launch template and 40-edge uses it as the target."
  value       = aws_security_group.workers.id
}

output "control_plane_security_group_id" {
  description = "Security group for the control plane ENI."
  value       = aws_security_group.control_plane.id
}

output "alb_security_group_arn" {
  description = "ARN of the ALB security group, for use in other layers' rules."
  value       = aws_security_group.alb.arn
}

output "node_instance_profile_name" {
  description = "Instance profile name to attach to control plane and worker instances."
  value       = aws_iam_instance_profile.node.name
}

output "node_instance_profile_arn" {
  description = "ARN of the node instance profile."
  value       = aws_iam_instance_profile.node.arn
}

output "node_role_arn" {
  description = "ARN of the node IAM role."
  value       = aws_iam_role.node.arn
}

output "ebs_kms_key_arn" {
  description = "KMS key ARN for EBS volume encryption. 30-cluster and the EBS CSI driver in Phase 7 must use this."
  value       = aws_kms_key.ebs.arn
}

output "ebs_kms_key_id" {
  description = "KMS key id for EBS volume encryption."
  value       = aws_kms_key.ebs.key_id
}

output "ebs_kms_key_alias" {
  description = "KMS alias for the EBS key."
  value       = aws_kms_alias.ebs.name
}

output "ssm_kms_key_arn" {
  description = "KMS key ARN used by SSM SecureString parameters."
  value       = aws_kms_key.ssm.arn
}

output "ssm_kms_key_id" {
  description = "KMS key id used by SSM SecureString parameters."
  value       = aws_kms_key.ssm.key_id
}

output "ssm_kms_key_alias" {
  description = "KMS alias for the SSM key."
  value       = aws_kms_alias.ssm.name
}

output "ssm_path_prefix" {
  description = "Parameter Store prefix the node role can read and write. Later layers must place their parameters under this prefix."
  value       = local.ssm_path_prefix
}

output "ssm_parameter_paths" {
  description = "Canonical parameter paths for the cluster and platform phases. Values are created in 30-cluster and 50-platform; only the paths are defined here."
  value = {
    bootstrap_script  = "${local.ssm_path_prefix}/bootstrap-script"
    bootstrap_output  = "${local.ssm_path_prefix}/bootstrap-output"
    join_command      = "${local.ssm_path_prefix}/kubeadm-join-command"
    join_ca_cert_hash = "${local.ssm_path_prefix}/kubeadm-ca-cert-hash"
    kubeconfig        = "${local.ssm_path_prefix}/admin-kubeconfig"
    argocd_repo_key   = "${local.ssm_path_prefix}/argocd-repo-deploy-key"
  }
}

output "etcd_backup_bucket_name" {
  description = "Etcd snapshot bucket name the node role is allowed to write. Phase 7 must create exactly this bucket."
  value       = var.etcd_backup_bucket_name
}

output "postgres_backup_bucket_name" {
  description = "PostgreSQL backup bucket name the node role is allowed to write. Phase 7 must create exactly this bucket."
  value       = var.postgres_backup_bucket_name
}

output "exposed_ports" {
  description = "Summary of every port this layer exposes, for review against docs/security-baseline.md. Port 22 must never appear here."
  value = {
    alb_http          = 80
    alb_https         = 443
    nodeports         = var.nodeports
    apiserver         = var.apiserver_port
    kubelet           = var.kubelet_port
    ssh_should_be_nil = tolist(["22"])
  }
}
