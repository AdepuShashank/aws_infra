output "scheduler_role_arn" {
  description = "Role the schedules assume. Null when scheduling is off."
  value       = one(aws_iam_role.scheduler[*].arn)
}

output "stop_schedule_arn" {
  description = "Schedule that stops the environment's instances, or null when scheduling is off."
  value       = one(aws_scheduler_schedule.stop[*].arn)
}

output "start_schedule_arn" {
  description = "Schedule that starts them again, or null when scheduling is off."
  value       = one(aws_scheduler_schedule.start[*].arn)
}

output "asg_schedules" {
  description = "The ASG capacity schedules. Empty when worker_asg_name is null - qa's group already rests at min 0 on its own."
  value = {
    stop  = one(aws_scheduler_schedule.stop_asg[*].arn)
    start = one(aws_scheduler_schedule.start_asg[*].arn)
  }
}

output "schedule_expressions" {
  description = "The two cron expressions currently in force, and the timezone they are evaluated in. Read this when the environment is stopped at an unexpected hour."
  value = {
    stop     = var.stop_schedule_expression
    start    = var.start_schedule_expression
    timezone = "Asia/Kolkata"
  }
}

output "status" {
  description = "Whether scheduling is actually on, and why not if it is not. enable_scheduling alone is not the whole answer: prod also needs allow_prod_scheduling."
  value = {
    enable_scheduling     = var.enable_scheduling
    allow_prod_scheduling = var.allow_prod_scheduling
    env                   = var.env
    schedules_created     = local.enabled
    targets_instances     = var.instance_ids
    target_worker_asg     = var.worker_asg_name
    asg_start_desired     = var.asg_start_desired_capacity
  }
}

output "cost_note" {
  description = "What this layer is billed for, since a schedule that costs money while doing nothing is worth knowing about."
  value = {
    per_invocation = "EventBridge Scheduler charges per invocation, not per schedule."
    window_off     = "flexible_time_window is ${var.flexible_time_window_enabled ? "ENABLED" : "OFF"}; an enabled window counts as a second invocation per firing."
    approximate    = "${length(var.instance_ids) > 0 ? 2 : 0}${var.worker_asg_name != null ? 4 : 0} invocations per week while enabled, which is cents, not dollars."
  }
}
