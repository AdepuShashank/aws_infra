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

output "control_plane_endpoint" {
  description = "Kubernetes API endpoint. Stable across control-plane replacement because it lives on a dedicated ENI."
  value       = module.cluster.control_plane_endpoint
}

output "control_plane_private_ip" {
  description = "Fixed private IP backing the API endpoint."
  value       = module.cluster.control_plane_private_ip
}

output "control_plane_instance_id" {
  description = "Control plane instance id, for SSM session targeting."
  value       = module.cluster.control_plane_instance_id
}

output "control_plane_eni_id" {
  description = "Dedicated control-plane ENI. Deleting this invalidates the API endpoint."
  value       = module.cluster.control_plane_eni_id
}

output "control_plane_security_group_id" {
  description = "Security group on the control-plane ENI."
  value       = module.cluster.control_plane_security_group_id
}

output "workers_security_group_id" {
  description = "Security group on the worker instances. 40-edge uses this as its target group's SG."
  value       = module.cluster.workers_security_group_id
}

output "worker_asg_name" {
  description = "Worker ASG name. 40-edge and 50-platform target this when tainting or cordoning."
  value       = module.cluster.worker_asg_name
}

output "worker_launch_template_id" {
  description = "Worker launch template."
  value       = module.cluster.worker_launch_template_id
}

output "worker_launch_template_latest_version" {
  description = "Latest worker launch template version."
  value       = module.cluster.worker_launch_template_latest_version
}

output "worker_capacity_details" {
  description = "Effective worker capacity mix."
  value       = module.cluster.worker_capacity_details
}

output "node_instance_profile_name" {
  description = "Instance profile attached to control plane and workers."
  value       = data.aws_iam_instance_profile.node.name
}

output "ami_id_used" {
  description = "AMI the nodes launched from."
  value       = module.cluster.ami_id_used
}

output "ami_resolution_method" {
  description = "How the AMI was resolved: override, ssm_parameter or describe_images."
  value       = module.cluster.ami_resolution_method
}

output "etcd_backup_bucket" {
  description = "Bucket receiving etcd snapshots. 70-backups references this rather than creating a second bucket."
  value       = module.cluster.etcd_backup_bucket
}

output "etcd_snapshot_bucket_arn" {
  description = "ARN of the etcd backup bucket."
  value       = module.cluster.etcd_snapshot_bucket_arn
}

output "ssm_join_command_parameter" {
  description = "SecureString parameter holding the current kubeadm join command."
  value       = module.cluster.ssm_join_command_parameter
}

output "ssm_kubeconfig_parameter" {
  description = "SecureString parameter holding the base64 admin kubeconfig."
  value       = module.cluster.ssm_kubeconfig_parameter
}

output "ssm_bootstrap_state_parameter" {
  description = "Plain String parameter recording control-plane bootstrap progress."
  value       = module.cluster.ssm_bootstrap_state_parameter
}

output "alb_target_group_arns" {
  description = "ALB target groups the worker ASG is registered with. Empty until 40-edge exists."
  value       = module.cluster.alb_target_group_arns
}

output "private_subnets" {
  description = "Private subnets the cluster nodes landed in."
  value = {
    for idx, s in local.private_subnets : s.az => {
      id   = s.id
      cidr = s.cidr
    }
  }
}

# ---------------------------------------------------------------------------
# For 50-platform
# ---------------------------------------------------------------------------
# The Calico IP pool has to match the podSubnet kubeadm was initialised with, and
# Argo CD's in-cluster domain is derived from the cluster name. 50-platform reads
# both from here rather than re-declaring them, because a second declaration is a
# second chance to disagree - and the disagreement is invisible until pods stop
# getting addresses.
output "cluster_name" {
  description = "Kubernetes cluster name, as passed to kubeadm. 50-platform uses it for the Argo CD in-cluster domain."
  value       = module.cluster.cluster_name
}

output "pod_cidr" {
  description = "Pod CIDR kubeadm was initialised with. 50-platform renders the Calico IP pool from exactly this value."
  value       = module.cluster.pod_cidr
}

output "service_cidr" {
  description = "Service CIDR kubeadm was initialised with. Recorded for reference; nothing in the platform layer depends on it."
  value       = module.cluster.service_cidr
}

output "kubernetes_version" {
  description = "Kubernetes minor version kubeadm deployed."
  value       = module.cluster.kubernetes_version
}

output "nodes" {
  description = "Per-node identifiers and addresses, for reaching a specific node over SSM."
  value = {
    control_plane_instance_id = module.cluster.control_plane_instance_id
    control_plane_private_ip  = module.cluster.control_plane_private_ip
    worker_asg_name           = module.cluster.worker_asg_name
    worker_capacity           = module.cluster.worker_capacity_details
  }
}
