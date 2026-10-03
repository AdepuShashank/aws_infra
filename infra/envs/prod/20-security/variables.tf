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
# ----------------------------------------------------------------- security ---

variable "traefik_nodeports" {
  description = <<-EOT
    NodePorts the ALB may reach on the workers. Traefik's HTTP NodePort is
    30080. HTTPS traffic terminates at the ALB, so it is not listed here.
    Port 22 is rejected by the module's validation: operator access is SSM
    Session Manager only.
  EOT
  type        = list(number)
  default     = [30080]
}

variable "ssm_path_prefix" {
  description = "Parameter Store prefix for cluster and platform parameters. Null derives /<project>/<env>/k8s."
  type        = string
  default     = null
}

variable "etcd_backup_bucket_name" {
  description = "Etcd snapshot bucket the node role may write. 70-backups creates a bucket with this exact name."
  type        = string
}

variable "postgres_backup_bucket_name" {
  description = "PostgreSQL backup bucket the node role may write. 70-backups creates a bucket with this exact name."
  type        = string
}

variable "kms_deletion_window_in_days" {
  description = "Waiting period before a scheduled KMS key deletion completes."
  type        = number
  default     = 30
}