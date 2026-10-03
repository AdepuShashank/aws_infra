variable "project" {
  description = "Project identifier."
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
  description = "Layer this module belongs to. Almost always 20-security."
  type        = string
  default     = "20-security"
}

variable "owner" {
  description = "Accountable owner tag value."
  type        = string
}

variable "cost_center" {
  description = "Cost allocation tag value."
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC created in 10-network."
  type        = string
}

variable "aws_region" {
  description = "Region the resources live in. Used to build SSM parameter ARNs."
  type        = string
  default     = "ap-south-1"
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC. Node-to-node rules are scoped to this, never to 0.0.0.0/0."
  type        = string
}

variable "allowed_cidrs" {
  description = "CIDR blocks allowed to reach the ALB on 80/443. Flows from modules/foundation as alb_allowed_cidrs."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.allowed_cidrs) > 0
    error_message = "allowed_cidrs must contain at least one CIDR block."
  }
}

variable "nodeports" {
  description = "NodePorts the load balancer may reach. Traefik's HTTP NodePort belongs here. Port 22 must never appear."
  type        = list(number)
  default     = [30080]

  validation {
    condition     = !contains(var.nodeports, 22)
    error_message = "SSH (22) must not be exposed as a NodePort; access is via SSM Session Manager only."
  }

  validation {
    condition     = alltrue([for p in var.nodeports : p >= 30000 && p <= 32767])
    error_message = "Every entry in nodeports must be inside the NodePort range 30000-32767."
  }
}

variable "apiserver_port" {
  description = "Kubernetes API server port."
  type        = number
  default     = 6443
}

variable "kubelet_port" {
  description = "Kubelet port. The control plane must accept it from nodes so kubectl logs/exec work."
  type        = number
  default     = 10250
}

variable "ssm_path_prefix" {
  description = <<-EOT
    Parameter Store prefix the nodes may read and write. Defaults to
    /<project>/<env>/k8s. The spec wrote /<env>/k8s/*; the project segment is
    added so this account can host more than one project without the paths
    colliding.
  EOT
  type        = string
  default     = null

  nullable = true
}

variable "etcd_backup_bucket_name" {
  description = "Name of the etcd snapshot bucket. The node role gets object access to this bucket only. Phase 7 must create a bucket with exactly this name."
  type        = string
}

variable "postgres_backup_bucket_name" {
  description = "Name of the PostgreSQL backup bucket. The node role gets object access to this bucket only. Phase 7 must create a bucket with exactly this name."
  type        = string
}

variable "kms_deletion_window_in_days" {
  description = "Waiting period before a scheduled KMS key deletion completes."
  type        = number
  default     = 30

  validation {
    condition     = var.kms_deletion_window_in_days >= 7 && var.kms_deletion_window_in_days <= 30
    error_message = "kms_deletion_window_in_days must be between 7 and 30."
  }
}

variable "enable_key_rotation" {
  description = "Enable automatic annual KMS key rotation. On for both keys."
  type        = bool
  default     = true
}
