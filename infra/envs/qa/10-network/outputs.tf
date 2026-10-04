output "layer" {
  description = "Layer name."
  value       = module.foundation.layer
}

output "env" {
  description = "Environment name."
  value       = module.foundation.env
}

output "name_prefix" {
  description = "Resource name prefix (project-env)."
  value       = module.foundation.name_prefix
}

output "standard_tags" {
  description = "Standard tag map applied to every resource in this layer."
  value       = module.foundation.standard_tags
}

output "aws_account_id" {
  description = "AWS account id resolved via STS."
  value       = module.foundation.aws_account_id
}

# ----------------------------------------------------- consumed by later layers ---

output "vpc_id" {
  description = "VPC that every other layer's resources live in."
  value       = module.network.vpc_id
}

output "vpc_cidr" {
  description = "VPC CIDR block."
  value       = module.network.vpc_cidr
}

output "public_subnet_ids" {
  description = "Public subnet IDs (ALB, NAT instance, control plane endpoint ENI)."
  value       = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs (Kubernetes nodes)."
  value       = module.network.private_subnet_ids
}

output "private_subnet_cidrs" {
  description = "Private subnet CIDR blocks, used for node security group rules."
  value       = module.network.private_subnet_cidrs
}

output "availability_zones" {
  description = "Availability zones in use."
  value       = module.network.availability_zones
}

output "internet_gateway_id" {
  description = "Internet gateway attached to the VPC."
  value       = module.network.internet_gateway_id
}

output "s3_gateway_endpoint_id" {
  description = "S3 gateway endpoint, so backups and registry pulls bypass the NAT instance."
  value       = module.network.s3_gateway_endpoint_id
}

output "nat_security_group_id" {
  description = "Security group used by the NAT instance(s)."
  value       = module.network.nat_security_group_id
}

output "nat_instance_id" {
  description = "Instance id of the NAT instance. 60-ops reads this from remote state as a scheduled-stop target: it is the one instance in this layer that costs money while doing nothing, and unlike the cluster it can be stopped and started without losing anything."
  value       = module.network.nat_instance_id
}

output "nat_spot_warning" {
  description = "Single point of failure warning for the NAT instance."
  value       = module.network.nat_spot_warning
}

output "flow_log_group_name" {
  description = "Flow log destination, or null when flow logs are disabled."
  value       = module.network.flow_log_group_name
}