variable "name" {
  description = "Name suffix for the network resources (e.g. \"main\")."
  type        = string
  default     = "main"
}

variable "vpc_cidr" {
  description = "IPv4 CIDR block for the VPC. Pod/service CIDRs must not overlap this."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }

  validation {
    # Must leave room for /24 subnets in the /16 range used by this project.
    condition     = tonumber(split("/", var.vpc_cidr)[1]) <= 24
    error_message = "vpc_cidr prefix must be /24 or shorter so that per-AZ subnets fit."
  }
}

variable "availability_zones" {
  description = "Availability zones to spread subnets across. Two are used per the spec."
  type        = list(string)

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "At least two availability zones are required."
  }

  validation {
    condition     = length(var.availability_zones) == length(distinct(var.availability_zones))
    error_message = "availability_zones must not contain duplicates."
  }
}

variable "public_subnet_offset" {
  description = "Subnet index offset for the public tier. Public uses N..N+n, private uses private_subnet_offset..+n."
  type        = number
  default     = 0
}

variable "private_subnet_offset" {
  description = "Subnet index offset for the private tier. 10 keeps private subnets visually distinct from public."
  type        = number
  default     = 10
}

variable "single_nat_instance" {
  description = "Must stay true. This module builds a single private route table, which can carry only one default route, so a NAT instance per AZ would silently break routing for the other AZs. Kept as an explicit variable so the constraint is visible instead of implied."
  type        = bool
  default     = true

  validation {
    condition     = var.single_nat_instance == true
    error_message = "single_nat_instance must be true; multi-AZ NAT would require one private route table per AZ."
  }
}

variable "nat_instance_type" {
  description = "Instance type for the NAT instance. t4g.nano is the cheapest Graviton option."
  type        = string
  default     = "t4g.nano"
}

variable "compute_enabled" {
  description = "Keep the NAT EC2 instance running. Set false to stop it without deleting it."
  type        = bool
  default     = true
}

variable "nat_ami_parameter" {
  description = "SSM public parameter for the NAT image. Ubuntu 24.04 arm64."
  type        = string
  default     = "/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id"
}

variable "enable_flow_logs" {
  description = "Publish VPC flow logs to CloudWatch Logs. Off by default to keep cost near zero."
  type        = bool
  default     = false
}

variable "flow_log_retention_days" {
  description = "CloudWatch Logs retention for flow logs. The spec asks for 14 days."
  type        = number
  default     = 14

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365], var.flow_log_retention_days)
    error_message = "flow_log_retention_days must be a retention value CloudWatch Logs accepts."
  }
}

variable "enable_s3_gateway_endpoint" {
  description = "Create the S3 gateway endpoint so private nodes reach S3 without NAT and without data transfer charges."
  type        = bool
  default     = true
}

variable "s3_endpoint_allowed_bucket_names" {
  description = "Bucket names reachable over the S3 gateway endpoint. Scoped deliberately narrow: the endpoint policy blocks the network path to every other bucket, while IAM and the bucket policies remain the authorization layer. Empty means no project buckets are reachable, which breaks etcd backups."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for b in var.s3_endpoint_allowed_bucket_names : can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", b))])
    error_message = "Each entry must be a bare S3 bucket name, for example dpx-prod-etcd-backups, not a full ARN."
  }
}

variable "interface_endpoint_services" {
  description = "Interface VPC endpoint services to create (e.g. ssm, ssm-message, ec2messages, ecr, ecr-dns, sts, logs). Each one costs roughly USD 0.01/hr in ap-south-1, so this defaults to empty and relies on the NAT instance for egress."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for s in var.interface_endpoint_services :
      contains(
        [
          "ssm", "ssm-message", "ec2messages", "ecr.api", "ecr.dkr",
          "sts", "logs", "autoscaling", "elasticloadbalancing",
        ],
        s
      )
    ])
    error_message = "interface_endpoint_services contains an unsupported endpoint service name. Use the exact service names (ecr.api / ecr.dkr / ssm-message)."
  }
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}