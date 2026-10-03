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
  default     = "10-network"
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

# ------------------------------------------------------------------ network ---

variable "vpc_cidr" {
  description = "IPv4 CIDR block for the VPC. Must not overlap the pod or service CIDRs (10.200.0.0/16 and 10.96.0.0/12)."
  type        = string
}

variable "availability_zone_count" {
  description = "Number of availability zones to spread across. The spec uses 2."
  type        = number
  default     = 2

  validation {
    condition     = var.availability_zone_count >= 2 && var.availability_zone_count <= 4
    error_message = "availability_zone_count must be between 2 and 4."
  }
}

variable "single_nat_instance" {
  description = "Run one NAT instance for all private subnets (cheapest) instead of one per AZ."
  type        = bool
  default     = true
}

variable "nat_instance_type" {
  description = "Instance type for the NAT instance. t4g.nano is the cheapest Graviton option."
  type        = string
  default     = "t4g.nano"
}

variable "compute_enabled" {
  description = "Keep the NAT EC2 instance running."
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Publish VPC flow logs to CloudWatch Logs. Costs roughly USD 0.50/GB ingested."
  type        = bool
  default     = false
}

variable "flow_log_retention_days" {
  description = "CloudWatch Logs retention for flow logs."
  type        = number
  default     = 14
}

variable "interface_endpoint_services" {
  description = "Interface VPC endpoint services. Empty by default; each costs about USD 7.30/month in ap-south-1."
  type        = list(string)
  default     = []
}