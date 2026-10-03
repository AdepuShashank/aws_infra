output "full_name" {
  description = "Fully-qualified resource name: project-env-name[-suffix]."
  value       = local.full_name
}

output "name_prefix" {
  description = "Common environment prefix: project-env."
  value       = local.name_prefix
}

output "tags" {
  description = "Standard tag map for the resource."
  value       = local.tags
}