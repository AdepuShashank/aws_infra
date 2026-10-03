variable "project" {
  description = "Project identifier used in resource names and tags. Lowercase, no spaces."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.project))
    error_message = "project must be lowercase alphanumeric/hyphen, 2-21 chars, starting with a letter."
  }
}

variable "env" {
  description = "Deployment environment."
  type        = string

  validation {
    condition     = contains(["prod", "qa"], var.env)
    error_message = "env must be one of: prod, qa."
  }
}

variable "layer" {
  description = "Terraform layer this root module represents (e.g. 10-network). Used for naming and tagging only."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{2}-[a-z-]+$", var.layer))
    error_message = "layer must look like NN-name, e.g. 10-network."
  }
}

variable "owner" {
  description = "Team or person accountable for the resources."
  type        = string
}

variable "cost_center" {
  description = "Cost allocation tag value."
  type        = string
}

variable "aws_region" {
  description = "AWS region for this environment."
  type        = string
  default     = "ap-south-1"

  validation {
    condition = contains(
      [
        "ap-south-1",
        "ap-south-2",
        "ap-southeast-1",
        "ap-southeast-2",
        "ap-northeast-1",
        "us-east-1",
        "us-east-2",
        "us-west-1",
        "us-west-2",
        "eu-west-1",
        "eu-central-1",
      ],
      var.aws_region
    )
    error_message = "aws_region must be a region where Graviton (arm64) and the required services are available."
  }
}

variable "extra_tags" {
  description = "Additional tags merged on top of the standard tag set."
  type        = map(string)
  default     = {}
}

variable "alb_allowed_cidrs" {
  description = "CIDR blocks allowed to reach the public ALB on 80/443. Use 0.0.0.0/0 only for throwaway environments."
  type        = list(string)

  validation {
    condition     = length(var.alb_allowed_cidrs) > 0
    error_message = "alb_allowed_cidrs must contain at least one CIDR block."
  }
}

variable "domain_name" {
  description = "Optional DNS name (e.g. example.com). When null, no Route 53 / ACM resources are created."
  type        = string
  default     = null

  validation {
    condition     = var.domain_name == null || can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.domain_name))
    error_message = "domain_name must be a valid DNS name or null."
  }
}