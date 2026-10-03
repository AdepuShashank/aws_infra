# TFLint configuration
# https://github.com/terraform-linters/tflint
config {
  call_module_type = "local"
  force            = false
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.44.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# Naming and documentation rules we enforce ourselves.
plugin "terraform_docs" {
  enabled = true
  preset  = "recommended"
}

rule "terraform_required_providers" { enabled = true }
rule "terraform_typed_variables" { enabled = true }
rule "terraform_documented_variables" { enabled = true }
rule "terraform_documented_outputs" { enabled = true }
rule "terraform_unused_declarations" { enabled = true }
rule "terraform_module_pinned_source" {
  enabled = true
  style   = "flexible"
}
rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

# Names come from the naming module, so the "must start with terraform-" prefix
# rule is not applicable to this repository.
rule "aws_s3_bucket_name_prefix" { enabled = false }

# Instance type validation differs per region; plan-time check scripts cover it.
rule "aws_instance_invalid_type" { enabled = false }