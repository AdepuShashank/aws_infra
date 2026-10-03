# ---------------------------------------------------------------------------
# Worker Auto Scaling Group
# ---------------------------------------------------------------------------
# Mixed instances policy: an on-demand base plus an optional spot tier.
#
# Why mixed rather than two ASGs: one ASG keeps the node count a single number to
# reason about, and the capacity mix is expressed as percentages. Two ASGs would
# mean two things to scale, two instance refresh cycles, and workers appearing
# and disappearing from both tiers at once.
#
# The spot tier is off by default. Spot Graviton instances get reclaimed with
# roughly a 2-minute notice, which is fine for stateless platform pods but not
# for anything that should not be interrupted. Keeping prod on-demand only and
# enabling spot for qa matches how the environments are actually used.

locals {
  # Held unencoded here so user-data-guard.tf can measure it against EC2's limit.
  # Encoding happens at each use site.
  worker_user_data = templatefile("${path.module}/templates/worker.sh.tftpl", {
    common           = local.common_user_data
    region           = var.aws_region
    ssm_join_command = local.ssm_join_command
    max_wait_seconds = var.worker_join_timeout_seconds
  })

  # Spot capacity is only mixed in when both the flag and a type list are given,
  # so an empty list cannot produce an ASG with a spot tier that can never be
  # satisfied.
  spot_enabled = var.enable_spot_workers && length(var.worker_spot_instance_types) > 0

  # Provider v6 dropped spot_max_percentage: the split between on-demand and
  # spot is now expressed only through the on-demand settings, and everything not
  # covered by the on-demand base goes to spot.
  #
  # OnDemandBaseCapacity is a floor, not a target: AWS refuses to let it exceed
  # DesiredCapacity, and since desired_capacity is pinned to min_size below, the
  # base has to be min_size too. Using max_size here instead makes the group
  # unsatisfiable whenever max_size is greater than min_size, which it is in both
  # environments.
  #
  # With the spot tier on, base = min_size keeps the floor of the group on-demand
  # and only growth above it can land on spot, so qa's group starts empty and
  # scales into spot. With the spot tier off, base = min_size plus 100% on-demand
  # above base pins the whole group on-demand, which is the AWS-documented way to
  # express an all-on-demand group and still leaves the overrides in place.
  on_demand_base_capacity  = var.worker_min_size
  on_demand_pct_above_base = local.spot_enabled ? 0 : 100

  # Instance types the ASG may launch, across both tiers.
  #
  # An ASG override block is not scoped to a purchase type: whatever types are
  # listed are available to on-demand and to spot alike, and the distribution
  # decides which one each instance actually gets. Passing only the on-demand
  # list would make worker_spot_instance_types a setting that changes nothing,
  # so the two lists are unioned here when the spot tier is on.
  worker_instance_types_all = local.spot_enabled ? distinct(concat(var.worker_instance_types, var.worker_spot_instance_types)) : var.worker_instance_types

  worker_tags = merge(local.resource_tags["worker_lt"], {
    Name = module.naming["worker_lt"].full_name
    Role = "worker"
  }, var.worker_pool_tags)
}

resource "aws_launch_template" "worker" {
  name_prefix            = "${module.naming["worker_lt"].full_name}-"
  image_id               = local.ami_id
  vpc_security_group_ids = [var.workers_security_group_id]
  user_data              = base64encode(local.worker_user_data)

  # No key_name: workers have no SSH path, only SSM Session Manager.
  #
  # No associate_public_ip_address either. That argument does not exist on
  # aws_launch_template in provider v6; public addressing is decided by the
  # subnet's MapPublicIpOnLaunch, which 10-network sets to false for private
  # subnets. A launch template can only force the opposite by declaring its own
  # network_interfaces block, which would then have to redeclare the subnet and
  # security group and would break the ASG's per-subnet spreading.

  iam_instance_profile {
    name = var.node_instance_profile_name
  }

  update_default_version = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  monitoring {
    enabled = true
  }

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      volume_size           = var.worker_root_volume_size
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = var.ebs_kms_key_arn
      delete_on_termination = true
    }
  }

  # Propagate the tag to the ASG so Capacity Insights and cost allocation can
  # attribute worker spend without a join through the ASG name.
  tag_specifications {
    resource_type = "instance"
    tags          = local.worker_tags
  }

  tag_specifications {
    resource_type = "volume"
    tags          = local.worker_tags
  }

  tags = local.worker_tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "workers" {
  name_prefix = "${module.naming["worker_asg"].full_name}-"

  # Spread workers across AZs. Two workers in one AZ would make that AZ a single
  # point of failure for the control plane's pod CIDR allocation and for any
  # topology-spread constraint.
  vpc_zone_identifier = var.private_subnet_ids

  min_size         = var.compute_enabled ? var.worker_min_size : 0
  max_size         = var.worker_max_size
  desired_capacity = var.compute_enabled ? var.worker_min_size : 0
  default_cooldown = 300

  # Replacing instances one at a time keeps at least one worker serving. Without
  # this the ASG terminates the whole group and reboots the cluster's workload
  # capacity on every config change.
  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 300
    }
  }

  # Always a mixed instances policy, including when the spot tier is off.
  #
  # on_demand_allocation_strategy must be "lowest-price", never "prioritized".
  # "prioritized" requires every launch template override to carry a priority,
  # and provider v6 removed the priority attribute from the override block: it
  # accepts only instance_type and weighted_capacity. AWS stores the policy and
  # then cannot allocate on-demand capacity from it, so the group reports the
  # scale-out activity as Successful, launches fewer instances than desired or
  # none at all, and never retries. Verified 2026-10-03 - desired 2, one worker
  # launched, zero failed activities, Terraform left waiting for capacity. The
  # value is the hyphenated "lowest-price"; the camelCase "lowestPrice" that older
  # examples show is rejected outright with
  # "OnDemandAllocationStrategy is not valid".
  mixed_instances_policy {
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.worker.id
        version            = aws_launch_template.worker.latest_version
      }

      # One override per instance type. In provider v6 override.instance_type
      # takes a single value, not a list, so a list has to be expanded here.
      #
      # Overrides only the instance type; everything else (AMI, user-data,
      # volumes) is inherited, which is what keeps the tiers identical.
      dynamic "override" {
        for_each = local.worker_instance_types_all

        content {
          instance_type     = override.value
          weighted_capacity = "100"
        }
      }
    }

    instances_distribution {
      on_demand_allocation_strategy = "lowest-price"

      on_demand_base_capacity                  = local.on_demand_base_capacity
      on_demand_percentage_above_base_capacity = local.on_demand_pct_above_base

      spot_allocation_strategy = "capacity-optimized"

      # Two pools so capacity-optimized can spread across instance families.
      # Omitted when spot is off so the request does not carry a pool count for a
      # policy with no spot capacity to distribute.
      spot_instance_pools = local.spot_enabled ? 2 : null
    }
  }

  # Register workers with the edge target group when 40-edge has created it.
  # Empty in Phase 4, so this is a no-op until then. In provider v6 this is a
  # plain attribute, not a block.
  target_group_arns = var.alb_target_group_arns

  dynamic "tag" {
    for_each = local.worker_tags

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    # The ASG name is generated by name_prefix; without this, replacement would
    # fail because the new group wants the old name.
    create_before_destroy = true
  }

  # The provider default is 10 minutes. Reaching it here is routine rather than
  # exceptional: Terraform polls DescribeScalingActivities while the group scales
  # out, and with instance_warmup = 300 plus a rolling refresh in flight the poll
  # regularly comes back with a context deadline exceeded of its own. A timeout
  # here fails the apply even though the group reached the capacity it was asked
  # for, which then has to be re-applied to record state.
  #
  # No create timeout exists on this resource; the provider only exposes update
  # and delete.
  timeouts {
    update = "20m"
    delete = "20m"
  }

  depends_on = [aws_launch_template.worker]
}
