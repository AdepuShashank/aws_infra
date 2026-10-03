terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  # The S3 backend is wired up in Phase 1 (infra/bootstrap) once the state
  # bucket exists. Until then every layer runs on local state so that
  # `terraform validate` works on a brand new checkout.
  #
  # backend "s3" {
  #   bucket       = "..."
  #   key          = "prod/10-network/terraform.tfstate"
  #   region       = "ap-south-1"
  #   encrypt      = true
  #   use_lockfile = true   # S3 native state locking (Terraform >= 1.10)
  # }
}