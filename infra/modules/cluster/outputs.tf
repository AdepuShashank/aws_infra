output "control_plane_private_ip" {
  description = "Fixed private IP of the control-plane ENI, which is also the stable kubeadm controlPlaneEndpoint."
  value       = local.control_plane_ip
}

output "control_plane_endpoint" {
  description = "Kubernetes API endpoint, stable across control-plane instance replacement."
  value       = local.control_plane_endpoint
}

output "control_plane_instance_id" {
  description = "Instance id of the control plane, for SSM session targeting."
  value       = aws_instance.control_plane.id
}

output "control_plane_public_state_name" {
  description = "EC2 instance state name of the control plane, for readiness polling."
  value       = aws_instance.control_plane.instance_state
}

output "control_plane_eni_id" {
  description = "The dedicated ENI. Deleting this is what invalidates the API endpoint."
  value       = aws_network_interface.control_plane.id
}

output "worker_asg_name" {
  description = "Name of the worker autoscaling group."
  value       = aws_autoscaling_group.workers.name
}

output "worker_launch_template_id" {
  description = "Worker launch template. Rolling it forces an instance refresh."
  value       = aws_launch_template.worker.id
}

output "worker_launch_template_latest_version" {
  description = "Latest version number of the worker launch template."
  value       = aws_launch_template.worker.latest_version
}

output "worker_capacity_details" {
  description = "Effective mixed-instances capacity mix, so the plan can be checked without reading the raw policy."
  value = {
    on_demand_instance_types = var.worker_instance_types
    spot_instance_types      = local.spot_enabled ? var.worker_spot_instance_types : []
    spot_enabled             = local.spot_enabled
    on_demand_base_capacity  = local.on_demand_base_capacity
    on_demand_pct_above_base = local.on_demand_pct_above_base
    min_size                 = var.compute_enabled ? var.worker_min_size : 0
    max_size                 = var.worker_max_size
  }
}

output "control_plane_security_group_id" {
  description = "Security group attached to the control-plane ENI."
  value       = var.control_plane_security_group_id
}

output "workers_security_group_id" {
  description = "Security group attached to worker instances."
  value       = var.workers_security_group_id
}

output "node_instance_profile_name" {
  description = "Instance profile attached to every node."
  value       = var.node_instance_profile_name
}

output "ami_id_used" {
  description = "AMI the nodes actually launched, so an unexpected jump can be traced to a config change."
  value       = local.ami_id
}

output "ami_resolution_method" {
  description = "How the AMI was resolved: override, ssm_parameter, or describe_images."
  value = local.use_override ? "override" : (
    local.use_ssm_parameter ? "ssm_parameter" : "describe_images"
  )
}

output "etcd_backup_bucket" {
  description = "Bucket receiving etcd snapshots. Shared with 70-backups."
  value       = aws_s3_bucket.etcd_backups.id
}

output "etcd_snapshot_bucket_arn" {
  description = "ARN of the etcd backup bucket."
  value       = aws_s3_bucket.etcd_backups.arn
}

output "ssm_join_command_parameter" {
  description = "SecureString parameter holding the current kubeadm join command."
  value       = local.ssm_join_command
}

output "ssm_kubeconfig_parameter" {
  description = "SecureString parameter holding the base64 admin kubeconfig."
  value       = local.ssm_kubeconfig
}

output "ssm_bootstrap_state_parameter" {
  description = "Plain String parameter recording control-plane bootstrap progress."
  value       = local.ssm_bootstrap_state
}

output "alb_target_group_arns" {
  description = "ALB target groups the worker ASG registers with. Empty until 40-edge exists."
  value       = var.alb_target_group_arns
}

# ---------------------------------------------------------------------------
# Cluster facts the platform layer needs
# ---------------------------------------------------------------------------
# Exported rather than re-read from tfvars in 50-platform. The Calico IP pool is
# rendered from pod_cidr, and an IP pool that does not match the kubeadm
# podSubnet produces a cluster where every pod sits in ContainerCreating with no
# useful error - so there is exactly one place pod_cidr is declared.
output "cluster_name" {
  description = "Kubernetes cluster name passed to kubeadm."
  value       = var.cluster_name
}

output "pod_cidr" {
  description = "Pod CIDR kubeadm was initialised with. The Calico IP pool must match this exactly."
  value       = var.pod_cidr
}

output "service_cidr" {
  description = "Service CIDR kubeadm was initialised with."
  value       = var.service_cidr
}

output "kubernetes_version" {
  description = "Kubernetes minor version kubeadm deployed. Reported for docs, not consumed by other layers."
  value       = var.kubernetes_version
}

output "ssm_path_prefix" {
  description = "Parameter Store prefix this cluster publishes into. 50-platform writes under the same prefix."
  value       = var.ssm_path_prefix
}