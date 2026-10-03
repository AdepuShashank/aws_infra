locals {
  az_count = length(var.availability_zones)

  # Public  -> public_subnet_offset + i   (0, 1, ...)
  # Private -> private_subnet_offset + i  (10, 11, ...)
  public_cidrs  = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 8, var.public_subnet_offset + i)]
  private_cidrs = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 8, var.private_subnet_offset + i)]

  tags = merge({ Component = "network" }, var.tags)
}

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = var.name })

  lifecycle {
    # The VPC CIDR is referenced by the control plane endpoint, the pod/service
    # CIDR choice and every security group rule. Changing it is a rebuild.
    precondition {
      condition     = can(regex("^10\\.(1|2)[0-9]?\\.", var.vpc_cidr))
      error_message = "vpc_cidr must start with 10.10.0.0/16 (prod) or 10.20.0.0/16 (qa) per the spec."
    }
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = var.name })
}

# ---------------------------------------------------------------------------
# Subnets
# ---------------------------------------------------------------------------

# Public: ALB, NAT instance, and the fixed control plane endpoint ENI.
resource "aws_subnet" "public" {
  count = local.az_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.tags, {
    Name = "${var.name}-public-${var.availability_zones[count.index]}"
    Tier = "public"
  })
}

# Private: Kubernetes nodes. No public IPs - egress goes through the NAT
# instance so that SSM Session Manager and image pulls work without SSH.
resource "aws_subnet" "private" {
  count = local.az_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.private_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = false

  tags = merge(local.tags, {
    Name = "${var.name}-private-${var.availability_zones[count.index]}"
    Tier = "private"
  })
}

# ---------------------------------------------------------------------------
# Routing
# ---------------------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-public" })
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = local.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-private" })
}

resource "aws_route_table_association" "private" {
  count = local.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# NOTE: no aws_vpc_dhcp_options block. DHCP options are an attribute of the VPC
# itself (vpc_dhcp_options_id) and cannot be managed as a separate resource in
# this provider version. The VPC default (AmazonProvidedDNS, no custom domain
# name) is exactly what is wanted here, so nothing needs to change.