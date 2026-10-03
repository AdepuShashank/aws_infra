terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.67"
    }
    tls = {
      # Only used when enable_https is true, to mint the self-signed certificate
      # the ALB presents. Pinned anyway so the lock file is the same either way.
      source  = "hashicorp/tls"
      version = "~> 4.4"
    }
  }
}
