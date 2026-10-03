terraform {
  # Remote state, created in Phase 1 (infra/bootstrap). Each layer gets its own
  # key so a corrupted or rolled-back layer state never takes the others with it.
  #
  # use_lockfile = true is S3-native state locking (conditional writes). It
  # requires Terraform >= 1.10 and replaces the separate DynamoDB lock table,
  # which would otherwise be another resource to manage and pay for.
  backend "s3" {
    bucket       = "dpx-tfstate-qa"
    key          = "qa/40-edge/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    kms_key_id   = "arn:aws:kms:ap-south-1:580857072251:key/d13a3322-1678-4d16-81a5-4774c146e6d8"
    use_lockfile = true
  }
}
