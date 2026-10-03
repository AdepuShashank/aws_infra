output "alb_arn" {
  description = "ARN of the ALB. Useful for security-group rules in other layers."
  value       = aws_lb.this.arn
}

output "alb_dns_name" {
  description = "Public DNS name of the ALB. This is how the environment is reached before a domain exists."
  value       = aws_lb.this.dns_name
}

output "alb_zone_id" {
  description = "Hosted zone id of the ALB, needed by Route 53 alias records."
  value       = aws_lb.this.zone_id
}

output "alb_https_dns_name" {
  description = "DNS name to use when https is enabled. Identical to alb_dns_name; the ALB serves both on one name."
  value       = aws_lb.this.dns_name
}

output "alb_url" {
  description = "Base URL for the environment, including the scheme that is actually enabled."
  value       = var.enable_https ? "https://${aws_lb.this.dns_name}" : "http://${aws_lb.this.dns_name}"
}

output "target_group_arn" {
  description = <<-EOT
    Target group ARN. 30-cluster takes this as alb_target_group_arns so the worker
    ASG registers its instances and the health check has something to check.
  EOT
  value       = aws_lb_target_group.this.arn
}

output "target_group_name" {
  description = "Name of the target group."
  value       = aws_lb_target_group.this.name
}

output "http_listener_arn" {
  description = "ARN of the HTTP listener."
  value       = aws_lb_listener.http.arn
}

output "https_listener_arn" {
  description = "ARN of the HTTPS listener, or null when HTTPS is disabled."
  value       = one(aws_lb_listener.https[*].arn)
}

output "certificate_arn" {
  description = "Certificate presented by the HTTPS listener, or null when HTTPS is disabled."
  value       = var.enable_https ? local.https_certificate_arn : null
}

output "acm_certificate_arn" {
  description = "ACM-issued certificate ARN, or null when no domain is configured."
  value       = one(aws_acm_certificate.domain[*].arn)
}

output "dns_record_fqdn" {
  description = "Fully-qualified name that resolves to the ALB, or null when no domain is configured."
  value       = one(aws_route53_record.alb[*].fqdn)
}

output "endpoint_summary" {
  description = "What a caller needs to reach the environment, and how to tell the three modes apart."
  value = {
    domain_mode        = local.domain_enabled
    dns_name           = aws_lb.this.dns_name
    fqdn               = one(aws_route53_record.alb[*].fqdn)
    scheme             = var.enable_https ? "https" : "http"
    redirects_to_https = var.enable_https && var.enable_redirect_to_https
    health_check_path  = var.traefik_health_check_path
  }
}
