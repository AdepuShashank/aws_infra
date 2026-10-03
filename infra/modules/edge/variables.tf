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

variable "vpc_id" {
  description = "VPC the ALB and its target group live in. Supplied by the layer root from 10-network."
  type        = string
}

variable "alb_security_group_id" {
  description = "Security group for the ALB. Supplied by the layer root from 20-security."
  type        = string
}

variable "traefik_http_nodeport" {
  description = <<-EOT
    NodePort Traefik serves plain HTTP on. This is the target group's port, so it
    must match traefik_nodeports in 20-security. HTTPS terminates at the ALB, so
    only the HTTP NodePort is targeted.
  EOT
  type        = number

  validation {
    condition     = var.traefik_http_nodeport >= 30000 && var.traefik_http_nodeport <= 32767
    error_message = "traefik_http_nodeport must be in the NodePort range 30000-32767."
  }
}

variable "traefik_health_check_path" {
  description = <<-EOT
    Path the ALB health check requests. Traefik's /ping, not /: Traefik answers /
    with 404 by design even when healthy, so checking / deregisters every healthy
    node.
  EOT
  type        = string
  default     = "/ping"
}

variable "traefik_health_check_matcher" {
  description = "HTTP status codes the ALB treats as healthy. Traefik's ping entrypoint answers 200."
  type        = string
  default     = "200"
}

variable "health_check_interval_seconds" {
  description = "Seconds between health checks."
  type        = number
  default     = 15
}

variable "health_check_timeout_seconds" {
  description = "Seconds to wait for a health check response. Must be lower than the interval."
  type        = number
  default     = 5

  validation {
    condition     = var.health_check_timeout_seconds < var.health_check_interval_seconds
    error_message = "health_check_timeout_seconds must be less than health_check_interval_seconds; AWS rejects a target group where it is not."
  }
}

variable "health_check_healthy_threshold" {
  description = "Consecutive successes before a target is marked healthy."
  type        = number
  default     = 2
}

variable "health_check_unhealthy_threshold" {
  description = "Consecutive failures before a target is marked unhealthy."
  type        = number
  default     = 3
}

variable "deregistration_delay_seconds" {
  description = "Seconds to let in-flight requests finish on a draining target."
  type        = number
  default     = 30
}

variable "alb_idle_timeout_seconds" {
  description = "Idle timeout for connections through the ALB."
  type        = number
  default     = 60
}

variable "alb_deletion_protection" {
  description = "Protect the ALB from accidental deletion. On by default so a mistyped `destroy` cannot take the environment's only entry point with it."
  type        = bool
  default     = true
}

variable "alb_access_logs_bucket" {
  description = "Optional S3 bucket for ALB access logs. null disables access logging, which is the default because access logs are billed per request."
  type        = string
  default     = null
}

variable "enable_https" {
  description = "Create the HTTPS listener. Off by default: there is no domain yet."
  type        = bool
  default     = false
}

variable "enable_redirect_to_https" {
  description = "Add an HTTP->HTTPS redirect rule. Requires enable_https; ignored otherwise so HTTP cannot be redirected onto a listener that does not exist."
  type        = bool
  default     = false
}

variable "alb_imported_certificate_arn" {
  description = "Use this ACM certificate for the HTTPS listener instead of generating one. Takes precedence over both ACM issuance and the self-signed certificate."
  type        = string
  default     = null
}

variable "domain_name" {
  description = "Optional Route 53 zone name. null creates no hosted zone lookup, no ACM certificate, no validation records and no DNS record."
  type        = string
  default     = null
}

variable "dns_record_name" {
  description = "Record name created in the zone when domain_name is set. Use \"@\" for the apex or a subdomain like \"k8s\"."
  type        = string
  default     = "@"
}

variable "tls_policy" {
  description = "ALB TLS policy. ELBSecurityPolicy-TLS13-1-2-2021-06 is the modern default; the older TFS policies are kept out because they allow TLS 1.0/1.1."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"

  validation {
    condition     = startswith(var.tls_policy, "ELBSecurityPolicy-")
    error_message = "tls_policy must be an ALB security policy name beginning with ELBSecurityPolicy-."
  }
}

variable "redirect_rule_priority" {
  description = "Priority of the HTTP->HTTPS redirect rule."
  type        = number
  default     = 1
}

variable "self_signed_common_name" {
  description = "Common name for the generated self-signed certificate. Defaults to the ALB's own DNS name via the layer root."
  type        = string
  default     = ""
}

variable "self_signed_validity_hours" {
  description = "Validity of the generated self-signed certificate. 8760h is one year."
  type        = number
  default     = 8760
}
