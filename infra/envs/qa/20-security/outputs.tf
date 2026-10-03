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
# ------------------------------------------- consumed by later layers ---

output "vpc_id" {
  description = "VPC the security groups live in, resolved by tag lookup."
  value       = local.vpc_id
}

output "vpc_cidr" {
  description = "VPC CIDR block. Node-to-node rules are scoped to this."
  value       = local.vpc.cidr_block
}

output "alb_security_group_id" {
  description = "40-edge attaches this to the load balancer."
  value       = module.security.alb_security_group_id
}

output "workers_security_group_id" {
  description = "30-cluster attaches this to the worker launch template; 40-edge uses it as the target group."
  value       = module.security.workers_security_group_id
}

output "control_plane_security_group_id" {
  description = "30-cluster attaches this to the control plane ENI."
  value       = module.security.control_plane_security_group_id
}

output "node_instance_profile_name" {
  description = "Instance profile for control plane and worker instances."
  value       = module.security.node_instance_profile_name
}

output "node_instance_profile_arn" {
  description = "ARN of the node instance profile."
  value       = module.security.node_instance_profile_arn
}

output "node_role_arn" {
  description = "ARN of the node IAM role."
  value       = module.security.node_role_arn
}

output "ebs_kms_key_arn" {
  description = "KMS key for EBS volume encryption. The EBS CSI driver uses this for gp3 PVCs."
  value       = module.security.ebs_kms_key_arn
}

output "ebs_kms_key_alias" {
  description = "KMS alias for the EBS key."
  value       = module.security.ebs_kms_key_alias
}

output "ssm_kms_key_arn" {
  description = "KMS key for SSM SecureString parameters."
  value       = module.security.ssm_kms_key_arn
}

output "ssm_kms_key_alias" {
  description = "KMS alias for the SSM key."
  value       = module.security.ssm_kms_key_alias
}

output "ssm_path_prefix" {
  description = "Parameter Store prefix later layers must write their parameters under."
  value       = module.security.ssm_path_prefix
}

output "ssm_parameter_paths" {
  description = "Canonical parameter paths for 30-cluster and 50-platform. Only the paths are defined here; the values are created by those layers."
  value       = module.security.ssm_parameter_paths
}

output "backup_bucket_names" {
  description = "Backup buckets the node role may write. 70-backups must create exactly these two."
  value = {
    etcd     = module.security.etcd_backup_bucket_name
    postgres = module.security.postgres_backup_bucket_name
  }
}

output "exposed_ports" {
  description = "Every port this layer exposes. Port 22 appears in ssh_should_be_nil so the absence of SSH is reviewable."
  value       = module.security.exposed_ports
}