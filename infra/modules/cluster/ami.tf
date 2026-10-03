# ---------------------------------------------------------------------------
# AMI resolution
# ---------------------------------------------------------------------------
# Preference order:
#   1. ami_id_override          (testing a specific image)
#   2. data.aws_ssm_parameter   (Canonical publishes the current AMI here)
#   3. DescribeImages filter    (fallback when the parameter is absent)
#
# Why the fallback exists: Canonical's /aws/service/canonical/... parameters are
# only present in regions where they have published, and they are not resolvable
# at all in some accounts. Verified absent in ap-south-1 for 24.04 arm64 while
# the equivalent Amazon Linux and 22.04 parameters resolved, so this is a real
# gap rather than a permissions problem. Without the fallback the module cannot
# plan in ap-south-1 at all.
#
# The DescribeImages filter takes the newest available image rather than a
# hardcoded name, so it tracks Ubuntu's point releases automatically. The AMI is
# then pinned in the launch template, which means the cluster only changes
# images when Terraform is re-applied, not on its own.

locals {
  use_override      = var.ami_id_override != ""
  use_ssm_parameter = !local.use_override && var.ami_ssm_parameter != ""
  use_discovery     = !local.use_override && var.ami_ssm_parameter == ""
}

data "aws_ssm_parameter" "ami" {
  count = local.use_ssm_parameter ? 1 : 0

  name = var.ami_ssm_parameter
}

data "aws_ami" "discovered" {
  count = local.use_discovery ? 1 : 0

  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  ami_id = local.use_override ? var.ami_id_override : (
    local.use_ssm_parameter ? data.aws_ssm_parameter.ami[0].value : data.aws_ami.discovered[0].id
  )
}

# The AMI must actually be arm64 with a gp3 root volume. A wrong-architecture
# image fails deep in kubeadm with an exec format error that gives no hint about
# the cause, and a gp2 root volume would silently skip the fast paths the EBS CSI
# driver expects. Both are caught at plan time instead.
data "aws_ami" "resolved" {
  filter {
    name   = "image-id"
    values = [local.ami_id]
  }
}

check "ami_is_arm64" {
  assert {
    condition     = data.aws_ami.resolved.architecture == "arm64"
    error_message = "AMI ${local.ami_id} is ${data.aws_ami.resolved.architecture}, expected arm64. The cluster is Graviton-only."
  }
}

locals {
  # Only the root device's volume type matters. block_device_mappings can also
  # contain ephemeral and non-root entries, so this narrows to the entry whose
  # device_name matches root_device_name.
  root_volume_type = try(
    [
      for b in data.aws_ami.resolved.block_device_mappings :
      b.ebs.volume_type
      if b.device_name == data.aws_ami.resolved.root_device_name
    ][0],
    null
  )
}

check "ami_root_device_is_gp3" {
  assert {
    condition     = local.root_volume_type == "gp3"
    error_message = "AMI ${local.ami_id} root volume is ${local.root_volume_type}, expected gp3. The launch template pins gp3, and a gp2 source image would either fail or silently differ from what was tested."
  }
}
