terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  # The S3 backend lives in backend.tf. It is kept in a separate file so the
  # bucket name, state key and KMS key can be regenerated from the bootstrap
  # outputs without touching this file's version constraints.
}
