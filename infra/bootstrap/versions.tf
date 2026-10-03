terraform {
  # NOTE: this layer deliberately uses LOCAL state.
  # It creates the very S3 bucket that every other layer uses as its backend,
  # so it cannot bootstrap itself. See docs/state-layout.md.
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.67"
    }
  }
}