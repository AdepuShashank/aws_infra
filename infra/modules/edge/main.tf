# ---------------------------------------------------------------------------
# Edge (Phase 5)
# ---------------------------------------------------------------------------
# One ALB in the public subnets, in front of Traefik's NodePort service.
#
# Design notes that are easy to get wrong:
#
# 1. The target group targets the INSTANCE, on the NodePort, not the pods. An
#    instance-type target group needs the node's IP; the ALB does the kube-proxy
#    NodePort translation. The alternative - an ip-type target group pointing at
#    pod IPs - breaks the moment Calico reuses a CIDR on another node, because
#    the ALB cannot reach a pod IP from outside the VPC routing table. Pod-level
#    routing is Traefik's job, not the load balancer's.
#
# 2. The health check hits Traefik's ping endpoint (`/ping` on the entrypoint),
#    not `/`. Traefik answers `/` with 404 by design even when healthy, so a `/`
#    health check marks every healthy node unhealthy and the ALB has no targets.
#    This is the single most common way an ALB-in-front-of-Traefik setup looks
#    broken when it is working.
#
# 3. Traefik binds the ping endpoint to `traefik` internally, so the ALB is
#    allowed to reach the NodePort and nothing else. The health check is the only
#    reason 30080 is reachable from the ALB at all; the application NodePort and
#    the Traefik admin port stay closed to the internet by the worker security
#    group in 20-security.
#
# 4. domain_name = null creates NO DNS and NO certificate. There is no placeholder
#    hosted zone and no dangling listener rule that depends on one; the HTTPS
#    listener and the redirect only exist when a zone name is supplied.

locals {
  name_prefix = "${var.project}-${var.env}"

  naming_resources = {
    alb            = "alb"
    alb_tg         = "alb-tg"
    https_listener = "alb-https"
    redirect       = "alb-redirect"
    acm_cert       = "alb-cert"
    dns_record     = "dns"
  }

  # Route 53 and ACM only exist when a domain is supplied.
  domain_enabled = var.domain_name != null

  # A certificate is generated only when HTTPS is on, there is no domain to get a
  # real certificate for, and no certificate was imported. Deriving all three
  # conditions in one local keeps the count expressions on the four resources that
  # share this decision from drifting apart.
  generate_self_signed = var.enable_https && !local.domain_enabled && var.alb_imported_certificate_arn == null
}

module "naming" {
  source = "../naming"

  for_each = local.naming_resources

  name        = each.value
  project     = var.project
  env         = var.env
  layer       = var.layer
  owner       = var.owner
  cost_center = var.cost_center
  component   = "edge"
}

locals {
  resource_tags = {
    for key, naming in module.naming : key => merge(naming.tags, var.extra_tags)
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# ---------------------------------------------------------------------------
# Subnets
# ---------------------------------------------------------------------------
# The ALB is public, so it goes in the public subnets. Public subnets are consumed
# here even though 30-cluster deliberately never touches them - an edge that
# cannot be attached to a public subnet is an edge that does not work, and saying
# so is better than an idle load balancer.
data "aws_subnets" "public" {
  filter {
    name   = "tag:Project"
    values = [var.project]
  }

  filter {
    name   = "tag:Env"
    values = [var.env]
  }

  filter {
    name   = "tag:ManagedBy"
    values = ["terraform"]
  }

  filter {
    name   = "tag:Component"
    values = ["network"]
  }

  filter {
    name   = "tag:Tier"
    values = ["public"]
  }
}

data "aws_subnet" "public" {
  for_each = toset(data.aws_subnets.public.ids)

  id = each.value
}

locals {
  subnet_az_order = sort([for s in data.aws_subnet.public : s.availability_zone])

  subnets_by_az = {
    for s in data.aws_subnet.public : s.availability_zone => s.id
  }

  public_subnet_ids = [for az in local.subnet_az_order : local.subnets_by_az[az]]
}

check "public_subnets_found" {
  assert {
    condition     = length(local.public_subnet_ids) >= 2
    error_message = "Found ${length(local.public_subnet_ids)} public subnet(s). An ALB needs at least two to be highly available across AZs; apply 10-network first."
  }
}

# ---------------------------------------------------------------------------
# ALB
# ---------------------------------------------------------------------------
# internal = false. access_logs off by default: they are per-request and a noisy
# bill on a portfolio environment that will serve mostly health checks.
resource "aws_lb" "this" {
  name                       = substr(module.naming["alb"].full_name, 0, 32)
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [var.alb_security_group_id]
  subnets                    = local.public_subnet_ids
  enable_deletion_protection = var.alb_deletion_protection
  idle_timeout               = var.alb_idle_timeout_seconds

  # access_logs off by default: billed per request, and this environment serves
  # mostly health checks. The block is dynamic rather than always-present because
  # aws_lb rejects an access_logs block with enabled = false and a null bucket.
  dynamic "access_logs" {
    for_each = var.alb_access_logs_bucket != null ? [var.alb_access_logs_bucket] : []

    content {
      bucket  = access_logs.value
      prefix  = "alb/${var.env}"
      enabled = true
    }
  }

  tags = local.resource_tags["alb"]
}

# HTTP is always on, and it is the only listener when there is no domain.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "forward"

    target_group_arn = aws_lb_target_group.this.arn
  }

  tags = local.resource_tags["alb"]
}

# ---------------------------------------------------------------------------
# Target group
# ---------------------------------------------------------------------------
resource "aws_lb_target_group" "this" {
  name        = substr(module.naming["alb_tg"].full_name, 0, 32)
  port        = var.traefik_http_nodeport
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  # Traefik's /ping, never /. Traefik returns 404 for / by design, and an ALB that
  # health checks / against Traefik deregisters every healthy node and then serves
  # 502 for a reason that has nothing to do with Traefik. See the module header.
  health_check {
    enabled             = true
    path                = var.traefik_health_check_path
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = var.traefik_health_check_matcher
    interval            = var.health_check_interval_seconds
    timeout             = var.health_check_timeout_seconds
    healthy_threshold   = var.health_check_healthy_threshold
    unhealthy_threshold = var.health_check_unhealthy_threshold
  }

  deregistration_delay = var.deregistration_delay_seconds

  tags = local.resource_tags["alb_tg"]

  lifecycle {
    # The port is Traefik's NodePort. Changing it changes the health check target,
    # and AWS replaces the target group rather than updating it, which silently
    # detaches a running ASG until the next apply.
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Optional HTTPS
# ---------------------------------------------------------------------------
# Self-signed unless a domain is supplied, in which case ACM issues a real one.
# The self-signed certificate is generated here rather than imported so that a
# fresh checkout works with no manual steps; `alb_imported_certificate_arn` exists
# for teams that would rather manage it in ACM/SSM themselves.
resource "tls_private_key" "self_signed" {
  count = local.generate_self_signed ? 1 : 0

  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "this" {
  count = local.generate_self_signed ? 1 : 0

  private_key_pem = tls_private_key.self_signed[0].private_key_pem

  subject {
    common_name  = var.self_signed_common_name
    organization = var.owner
  }

  dns_names             = compact([var.self_signed_common_name, "localhost"])
  validity_period_hours = var.self_signed_validity_hours

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

# An ALB listener takes a certificate ARN, not a PEM, so a generated certificate
# has to be uploaded to IAM to get one. This is also the "imported self-signed
# cert" the spec refers to, reached by generating rather than importing: a fresh
# checkout has no certificate to import.
#
# IAM server certificate names are account-global and cannot be changed in place,
# so the name carries a short suffix. Re-creating one is otherwise a destroy and
# create, which detaches the listener for the length of the apply.
resource "aws_iam_server_certificate" "self_signed" {
  count = local.generate_self_signed ? 1 : 0

  name_prefix      = substr("${module.naming["alb_cert"].full_name}-", 0, 100)
  certificate_body = tls_self_signed_cert.this[0].cert_pem
  private_key      = tls_private_key.self_signed[0].private_key_pem

  tags = local.resource_tags["acm_cert"]
}

locals {
  # Exactly one certificate source, in precedence order: an explicitly imported
  # ARN, then ACM (domain mode), then the generated self-signed certificate.
  #
  # The imported ARN is passed straight through rather than looked up in a
  # data source: data.aws_acm_certificate exports only computed attributes, so
  # there is no `arn` argument to set and nothing to validate against. A typo in
  # the ARN surfaces as a listener creation failure, which names it.
  https_certificate_arn = (
    var.alb_imported_certificate_arn != null ? var.alb_imported_certificate_arn :
    local.domain_enabled ? aws_acm_certificate_validation.domain[0].certificate_arn :
    local.generate_self_signed ? aws_iam_server_certificate.self_signed[0].arn : null
  )
}

# ---------------------------------------------------------------------------
# Optional DNS + ACM
# ---------------------------------------------------------------------------
data "aws_route53_zone" "this" {
  count = local.domain_enabled ? 1 : 0

  name = var.domain_name
}

# ACM validation by DNS, because the ALB has no other way to prove ownership. The
# record is created in the same apply as the validation record, so the domain must
# already be registered and this account must already be its nameserver - which is
# why domain_name stays null until a domain is actually bought.
resource "aws_acm_certificate" "domain" {
  count = local.domain_enabled ? 1 : 0

  domain_name       = var.domain_name
  validation_method = "DNS"

  tags = local.resource_tags["acm_cert"]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "acm_validation" {
  for_each = local.domain_enabled ? {
    for o in aws_acm_certificate.domain[0].domain_validation_options : o.domain_name => {
      name  = o.resource_record_name
      type  = o.resource_record_type
      value = o.resource_record_value
    }
  } : {}

  zone_id         = data.aws_route53_zone.this[0].zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "domain" {
  count = local.domain_enabled ? 1 : 0

  certificate_arn         = aws_acm_certificate.domain[0].arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}

resource "aws_route53_record" "alb" {
  count = local.domain_enabled ? 1 : 0

  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = var.dns_record_name
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }

  # No tags block: aws_route53_record is not a taggable resource. Alias records
  # carry the zone and the target, and nothing else.
}

# ---------------------------------------------------------------------------
# Optional HTTPS listeners
# ---------------------------------------------------------------------------
resource "aws_lb_listener" "https" {
  count = var.enable_https ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.tls_policy
  certificate_arn   = local.https_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }

  tags = local.resource_tags["https_listener"]
}

# Redirect only makes sense once there is an HTTPS listener to redirect to; with
# enable_https off this stays empty rather than looping HTTP back onto itself.
resource "aws_lb_listener_rule" "redirect" {
  count = var.enable_redirect_to_https ? 1 : 0

  listener_arn = aws_lb_listener.http.arn
  priority     = var.redirect_rule_priority

  # A listener rule needs at least one condition or AWS rejects it. This is the
  # catch-all, so it matches every path rather than relying on there being no
  # condition - which is not a thing the API allows.
  condition {
    path_pattern {
      values = ["*"]
    }
  }

  action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
      host        = "#{host}"
      path        = "/#{path}"
      query       = "#{query}"
    }
  }
}
