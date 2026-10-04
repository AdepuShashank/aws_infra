variable "project" {
  description = "Project identifier used in resource names and tags."
  type        = string
}

variable "env" {
  description = "Deployment environment (prod or qa)."
  type        = string

  validation {
    condition     = contains(["prod", "qa"], var.env)
    error_message = "env must be one of: prod, qa."
  }
}

variable "layer" {
  description = "This Terraform layer."
  type        = string
  default     = "30-cluster"
}

variable "owner" {
  description = "Accountable owner tag value."
  type        = string
}

variable "cost_center" {
  description = "Cost allocation tag value."
  type        = string
}

variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "ap-south-1"
}

variable "standard_tags" {
  description = "Standard tag map produced by the foundation module."
  type        = map(string)
}

variable "extra_tags" {
  description = "Additional tags merged on top of the standard tag set."
  type        = map(string)
  default     = {}
}

# --------------------------------------------------------------------- AMI ---

variable "ami_ssm_parameter" {
  description = <<-EOT
    SSM public parameter holding the Ubuntu arm64 AMI id.

    Empty string means "resolve the AMI with a DescribeImages call instead",
    which is the fallback for regions where Canonical has not published the
    parameter.
  EOT
  type        = string
  default     = "/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/snapd/rootfs/arm64"
}

variable "ami_id_override" {
  description = "Skip AMI resolution entirely and use this AMI id. Intended for testing a specific image."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------- networking ---

variable "vpc_id" {
  description = "VPC the cluster runs in."
  type        = string
}

variable "vpc_cidr" {
  description = <<-EOT
    VPC CIDR, used only to assert that pod_cidr and service_cidr are disjoint
    from it. An overlap here is invisible until pod traffic stops working.
  EOT
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet ids, one per availability zone."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 1
    error_message = "At least one private subnet is required."
  }
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs, parallel to private_subnet_ids. Used to pick the control-plane fixed IP."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_cidrs) == length(var.private_subnet_ids)
    error_message = "private_subnet_cidrs and private_subnet_ids must be the same length and in the same order."
  }
}

variable "control_plane_fixed_ip_offset" {
  description = <<-EOT
    Host offset within the first private subnet reserved for the control-plane
    ENI. 10 is the AWS convention for the first user-assigned address; 0-3 are
    reserved by AWS for the router and DHCP.
  EOT
  type        = number
  default     = 10

  validation {
    condition     = var.control_plane_fixed_ip_offset >= 5 && var.control_plane_fixed_ip_offset <= 250
    error_message = "control_plane_fixed_ip_offset must be between 5 and 250; AWS reserves .0-.4 and .255."
  }
}

variable "control_plane_security_group_id" {
  description = "Security group for the control plane, from 20-security."
  type        = string
}

variable "workers_security_group_id" {
  description = "Security group for the workers, from 20-security."
  type        = string
}

# ------------------------------------------------------------------- IAM/KMS ---

variable "node_instance_profile_name" {
  description = "Instance profile name from 20-security, attached to every node."
  type        = string
}

variable "ebs_kms_key_arn" {
  description = "KMS key ARN for node root volumes, from 20-security."
  type        = string
}

variable "ssm_path_prefix" {
  description = "SSM Parameter Store prefix where the control plane publishes the join command and kubeconfig."
  type        = string
}

# ------------------------------------------------------------- Kubernetes ---

variable "kubernetes_version" {
  description = "Kubernetes version. Used for the apt package pin and the kubeadm config."
  type        = string
  default     = "1.36.5"
}

variable "containerd_repo_ubuntu" {
  description = <<-EOT
    Ubuntu codename used for the Docker apt repository. containerd comes from
    Docker's repo rather than Ubuntu's archive on purpose: pkgs.k8s.io and
    Kubernetes releases assume a containerd 2.x CRI, while Ubuntu noble ships
    1.6.x, whose CRI plugin registration differs enough that kubeadm reports a
    misleading "container runtime is not running".
  EOT
  type        = string
  default     = "noble"
}

variable "containerd_version_pin" {
  description = <<-EOT
    Optional exact containerd.io version to pin, empty for newest available.
    Left unpinned by default so security patches arrive; kubeadm tolerates
    containerd minor drift, and the CRI socket path has been stable across
    containerd 1.x and 2.x.
  EOT
  type        = string
  default     = ""
}

variable "pod_cidr" {
  description = "Pod network CIDR. Must not overlap the VPC or the service CIDR."
  type        = string
  default     = "10.200.0.0/16"
}

variable "service_cidr" {
  description = "Service network CIDR. Must not overlap the VPC or the pod CIDR."
  type        = string
  default     = "10.96.0.0/12"
}

variable "cluster_name" {
  description = "Kubernetes cluster name written into the kubeadm config."
  type        = string
  default     = "dpx"
}

variable "api_server_port" {
  description = "Kubernetes API server port."
  type        = number
  default     = 6443
}

variable "apiserver_cert_sans" {
  description = "Extra SANs for the API server certificate, beyond the fixed IP and localhost."
  type        = list(string)
  default     = []
}

# ------------------------------------------------------------ node sizing ---

variable "control_plane_instance_type" {
  description = "Control plane instance type."
  type        = string
  default     = "t4g.medium"
}

variable "control_plane_root_volume_size" {
  description = "Control plane root volume size in GiB."
  type        = number
  default     = 30
}

variable "worker_instance_types" {
  description = "Instance types for the worker on-demand tier."
  type        = list(string)
  default     = ["t4g.medium"]
}

variable "worker_spot_instance_types" {
  description = <<-EOT
    Instance types for the optional worker spot tier. Empty disables spot
    workers entirely, which is the default for prod.
  EOT
  type        = list(string)
  default     = []
}

variable "worker_min_size" {
  description = "Minimum worker count (on-demand tier)."
  type        = number
  default     = 2
}

variable "compute_enabled" {
  description = "Keep cluster compute running. Set false to stop the control plane and scale workers to zero."
  type        = bool
  default     = true
}

variable "worker_max_size" {
  description = "Maximum worker count (on-demand tier)."
  type        = number
  default     = 3
}

variable "worker_root_volume_size" {
  description = "Worker root volume size in GiB."
  type        = number
  default     = 30
}

variable "enable_spot_workers" {
  description = <<-EOT
    Whether to add a spot capacity tier to the worker ASG. Enabled for qa,
    disabled for prod, where on-demand only is the default.
  EOT
  type        = bool
  default     = false
}

variable "alb_target_group_arns" {
  description = <<-EOT
    ALB target group ARNs the worker ASG registers with.

    Empty in Phase 4 because 40-edge has not created the target group yet.
    Populate it once 40-edge exists; a cross-layer variable would create a
    dependency cycle (30-cluster -> 40-edge -> 30-cluster), so the value is
    passed in from the environment's tfvars instead.
  EOT
  type        = list(string)
  default     = []
}

# ------------------------------------------------------------- etcd backup ---

variable "etcd_backup_bucket_name" {
  description = "S3 bucket for etcd snapshots. Created here; 60-ops reuses the name."
  type        = string
}

variable "etcd_snapshot_interval_hours" {
  description = "Hours between etcd snapshots."
  type        = number
  default     = 6
}

variable "etcd_snapshot_retention_days" {
  description = "Days to keep etcd snapshots before the bucket lifecycle expires them."
  type        = number
  default     = 14
}

variable "worker_join_timeout_seconds" {
  description = <<-EOT
    How long a worker waits for the control plane to publish a join command
    before giving up and exiting non-zero.

    Long enough to cover a cold first boot of a t4g.medium control plane doing
    kubeadm init plus container image pulls; short enough that a genuinely
    broken cluster does not hold a spot interruption open indefinitely.
  EOT
  type        = number
  default     = 2700
}

variable "worker_pool_tags" {
  description = "Extra key/value pairs baked into every node's EC2 tags."
  type        = map(string)
  default     = {}
}
