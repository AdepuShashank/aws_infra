# ---------------------------------------------------------------------------
# User data size guard
# ---------------------------------------------------------------------------
# EC2 refuses RunInstances with:
#
#   InvalidParameterValue: Encoded User data is limited to 25600 bytes
#
# which surfaces from a control plane or worker launch as a scaling-activity
# failure or an apply error partway through, long after the template edit that
# caused it and with no pointer back to which file grew.
#
# The documented limit is 16 KiB of raw user data. Base64 expands that to roughly
# 21.8 KiB, so the raw limit binds first and is the one worth asserting; the
# 25600-byte ceiling is checked as well so neither limit is reached by surprise.
#
# A precondition rather than a check block, because check blocks only warn. This
# has to stop the plan.
#
# Keeping the scripts inside the limit is also why the templates carry terse
# comments: the rationale for the bootstrap choices is written here and in the
# .tf files, which no instance has to download.

locals {
  # Both limits, named so the error message can say which one was crossed.
  user_data_raw_limit     = 16384
  user_data_encoded_limit = 25600

  control_plane_user_data_bytes = length(local.control_plane_user_data)
  worker_user_data_bytes        = length(local.worker_user_data)

  control_plane_user_data_encoded_bytes = length(base64encode(local.control_plane_user_data))
  worker_user_data_encoded_bytes        = length(base64encode(local.worker_user_data))

  # The shared bootstrap must appear exactly once in each rendered payload.
  #
  # It is inlined by interpolation, and templatefile expands dollar-brace
  # expressions inside shell *comments* as well as code. A comment that merely
  # named the variable therefore injected a second, silent copy of the whole
  # shared bootstrap into the worker payload. bash -n passed on the result: the
  # copy landed inside a comment, and the sentence's trailing period was left
  # behind as a bare "." line that bash then ran as `source` with no argument.
  # The worker died at cloud-init with
  #   line 158: .: filename argument required
  # before ever reaching the join, while the control plane - which has no such
  # comment - passed every test. Counting the copies catches the whole class at
  # plan time instead of on an instance that is already discarded.
  shared_bootstrap_marker = "starting shared node bootstrap"

  control_plane_shared_bootstrap_copies = length(regexall(local.shared_bootstrap_marker, local.control_plane_user_data))
  worker_shared_bootstrap_copies        = length(regexall(local.shared_bootstrap_marker, local.worker_user_data))
}

resource "terraform_data" "user_data_size" {
  # input is only used to make this resource show a diff when the rendered
  # scripts change; the assertions are what actually enforce the limit.
  input = sha256("${local.control_plane_user_data_bytes}-${local.worker_user_data_bytes}")

  lifecycle {
    precondition {
      condition     = local.control_plane_user_data_bytes <= local.user_data_raw_limit
      error_message = "control-plane user data is ${local.control_plane_user_data_bytes} raw bytes, over EC2's ${local.user_data_raw_limit}-byte limit. Trim templates/control-plane.sh.tftpl or move work out of cloud-init."
    }

    precondition {
      condition     = local.worker_user_data_bytes <= local.user_data_raw_limit
      error_message = "worker user data is ${local.worker_user_data_bytes} raw bytes, over EC2's ${local.user_data_raw_limit}-byte limit. Trim templates/worker.sh.tftpl or move work out of cloud-init."
    }

    precondition {
      condition     = local.control_plane_user_data_encoded_bytes <= local.user_data_encoded_limit
      error_message = "control-plane user data is ${local.control_plane_user_data_encoded_bytes} base64 bytes, over EC2's ${local.user_data_encoded_limit}-byte limit."
    }

    precondition {
      condition     = local.worker_user_data_encoded_bytes <= local.user_data_encoded_limit
      error_message = "worker user data is ${local.worker_user_data_encoded_bytes} base64 bytes, over EC2's ${local.user_data_encoded_limit}-byte limit."
    }

    precondition {
      condition     = local.control_plane_shared_bootstrap_copies == 1
      error_message = "control-plane user data inlines the shared bootstrap ${local.control_plane_shared_bootstrap_copies} times, expected once. A dollar-brace expression written inside a shell comment in templates/control-plane.sh.tftpl is being expanded there."
    }

    precondition {
      condition     = local.worker_shared_bootstrap_copies == 1
      error_message = "worker user data inlines the shared bootstrap ${local.worker_shared_bootstrap_copies} times, expected once. A dollar-brace expression written inside a shell comment in templates/worker.sh.tftpl is being expanded there."
    }
  }
}
