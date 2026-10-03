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

variable "extra_tags" {
  description = "Additional tags merged on top of the standard tag set."
  type        = map(string)
  default     = {}
}

variable "alb_allowed_cidrs" {
  description = "CIDR blocks allowed to reach the public ALB on 80/443."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "domain_name" {
  description = "Optional DNS name. null disables all Route 53 / ACM resources."
  type        = string
  default     = null
}

# --------------------------------------------------------------- AMI lookup ---

variable "ami_ssm_parameter" {
  description = <<-EOT
    SSM public parameter holding the Ubuntu arm64 AMI id. Empty means "resolve
    it with DescribeImages instead".

    Empty by default: Canonical has not published the 24.04 arm64 parameters in
    ap-south-1, and a non-empty value that cannot be resolved fails the plan with
    ParameterNotFound rather than falling back.
  EOT
  type        = string
  default     = ""
}

variable "ami_id_override" {
  description = "Use this AMI id verbatim and skip all AMI resolution. For testing a specific image."
  type        = string
  default     = ""
}

# ----------------------------------------------------------------- cluster ---

variable "kubernetes_version" {
  description = "Kubernetes minor version. Patches to the package set and kubeadm config."
  type        = string
  default     = "1.36.5"
}

variable "cluster_name" {
  description = "Cluster name written into the kubeadm config. Must match the CFQDN pattern kubeadm allows."
  type        = string
  default     = "dpx"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.cluster_name))
    error_message = "cluster_name must be a lowercase RFC 1123 label: letters, digits and dashes, no leading or trailing dash."
  }
}

variable "pod_cidr" {
  description = "Pod network CIDR. Must not overlap the VPC or service_cidr."
  type        = string
  default     = "10.200.0.0/16"
}

variable "service_cidr" {
  description = "Service network CIDR. Must not overlap the VPC or pod_cidr."
  type        = string
  default     = "10.96.0.0/12"
}

variable "control_plane_fixed_ip_offset" {
  description = <<-EOT
    Host offset within the first private subnet for the control-plane ENI.

    .10, not .20: 20-security and 10-network reserve low addresses in these
    subnets, and .10 is both the AWS convention for the first user-assigned
    address and the one verified free in both environments.
  EOT
  type        = number
  default     = 10
}

variable "control_plane_instance_type" {
  description = "Control plane instance type."
  type        = string
  default     = "t4g.medium"
}

variable "control_plane_root_volume_size" {
  description = "Control plane root volume size in GiB. etcd data lives here, so this is the one volume whose loss is unrecoverable without a restore from S3."
  type        = number
  default     = 30
}

# ----------------------------------------------------------------- workers ---

variable "worker_instance_types" {
  description = "On-demand instance types for the worker ASG."
  type        = list(string)
  default     = ["t4g.medium"]
}

variable "worker_min_size" {
  description = "Minimum worker count."
  type        = number
  default     = 2
}

variable "compute_enabled" {
  description = "Keep cluster compute running."
  type        = bool
  default     = true
}

variable "worker_max_size" {
  description = "Maximum worker count."
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
    Add a spot capacity tier to the worker ASG. On for qa, off for prod: spot
    Graviton instances are reclaimed on roughly two minutes notice, which is
    fine for disposable platform pods and not fine for prod workloads.
  EOT
  type        = bool
  default     = false
}

variable "worker_spot_instance_types" {
  description = "Spot instance types. Ignored unless enable_spot_workers is true."
  type        = list(string)
  default     = ["t4g.medium", "t4g.large"]
}



variable "worker_pool_tags" {
  description = "Extra tags baked onto every worker. Populated by 50-platform when it creates a taint-specific pool."
  type        = map(string)
  default     = {}
}

# -------------------------------------------------------------------- edge ---

variable "alb_target_group_arns" {
  description = <<-EOT
    ALB target groups the worker ASG registers with. Empty in Phase 4, since
    40-edge has not created the target group yet. Setting this before the target
    group exists makes the ASG fail to register.
  EOT
  type        = list(string)
  default     = []
}

# ----------------------------------------------------------------- backups ---

variable "etcd_backup_bucket_name" {
  description = "Bucket for etcd snapshots. Must match the name 20-security grants the node role access to."
  type        = string
}
