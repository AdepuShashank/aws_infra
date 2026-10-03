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
  default     = "40-edge"
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
# --------------------------------------------------------------- Traefik ---
# NodePort Traefik serves plain HTTP on. HTTPS terminates at the ALB, so only the
# HTTP NodePort is targeted. Must be one of the traefik_nodeports granted in
# 20-security; the check block in main.tf enforces that they agree.
variable "traefik_http_nodeport" {
  description = "NodePort the ALB target group targets. Must match a value in traefik_nodeports in 20-security."
  type        = number
  default     = 30080

  validation {
    condition     = var.traefik_http_nodeport >= 30000 && var.traefik_http_nodeport <= 32767
    error_message = "traefik_http_nodeport must be in the NodePort range 30000-32767."
  }
}

# ------------------------------------------------------------------ HTTPS ---
# No domain yet, so HTTPS is off and the environment is reached on the ALB's own
# DNS name over plain HTTP. Turning enable_https on with domain_name still null
# serves a generated self-signed certificate, which browsers warn about - useful
# for proving the listener works, not for anything else.
variable "enable_https" {
  description = "Create the HTTPS listener."
  type        = bool
  default     = false
}

variable "enable_redirect_to_https" {
  description = "Redirect HTTP to HTTPS. Only meaningful when enable_https is also true."
  type        = bool
  default     = false
}

variable "alb_imported_certificate_arn" {
  description = "Use this ACM certificate instead of generating one. Takes precedence over both ACM issuance and the self-signed certificate."
  type        = string
  default     = null
}

variable "dns_record_name" {
  description = "Record name created in the zone when domain_name is set. Use \"@\" for the apex, or a subdomain such as \"k8s\"."
  type        = string
  default     = "@"
}

variable "tls_policy" {
  description = "ALB TLS policy."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

variable "self_signed_common_name" {
  description = "Common name for the generated self-signed certificate. Empty derives it from the ALB's own DNS name."
  type        = string
  default     = ""
}

# ------------------------------------------------------------------- ALB ---
# Deletion protection is on: the ALB is the environment's only entry point, and a
# mistyped `terraform destroy` should not take it out without a deliberate act.
variable "alb_deletion_protection" {
  description = "Protect the ALB from accidental deletion."
  type        = bool
  default     = true
}

variable "alb_access_logs_bucket" {
  description = "Optional S3 bucket for ALB access logs. null disables logging, which is the default because access logs are billed per request."
  type        = string
  default     = null
}

variable "alb_idle_timeout_seconds" {
  description = "Idle timeout for connections through the ALB."
  type        = number
  default     = 60
}