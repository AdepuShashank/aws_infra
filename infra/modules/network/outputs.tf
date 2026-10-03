output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "IPv4 CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "vpc_arn" {
  description = "ARN of the VPC."
  value       = aws_vpc.this.arn
}

output "internet_gateway_id" {
  description = "ID of the internet gateway attached to the VPC."
  value       = aws_internet_gateway.this.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs, in the same order as availability_zones."
  value       = aws_subnet.public[*].id
}

output "public_subnet_cidrs" {
  description = "Public subnet CIDR blocks."
  value       = aws_subnet.public[*].cidr_block
}

output "private_subnet_ids" {
  description = "Private subnet IDs, in the same order as availability_zones."
  value       = aws_subnet.private[*].id
}

output "private_subnet_cidrs" {
  description = "Private subnet CIDR blocks."
  value       = aws_subnet.private[*].cidr_block
}

output "availability_zones" {
  description = "Availability zones the subnets were placed in."
  value       = var.availability_zones
}

output "public_route_table_id" {
  description = "Route table used by the public subnets."
  value       = aws_route_table.public.id
}

output "private_route_table_id" {
  description = "Route table used by the private subnets."
  value       = aws_route_table.private.id
}

output "s3_gateway_endpoint_id" {
  description = "ID of the S3 gateway endpoint, or null when disabled."
  value       = one(aws_vpc_endpoint.s3[*].id)
}

output "interface_endpoint_ids" {
  description = "IDs of any interface VPC endpoints created."
  value       = aws_vpc_endpoint.interface[*].id
}

output "nat_security_group_id" {
  description = "Security group attached to the NAT instances."
  value       = aws_security_group.nat.id
}

output "nat_instance_id" {
  description = "Instance id of the NAT instance."
  value       = aws_instance.nat.id
}

output "nat_primary_eni_id" {
  description = "Primary ENI of the NAT instance; this is what the private default route targets."
  value       = aws_instance.nat.primary_network_interface_id
}

output "nat_spot_warning" {
  description = "Human-readable warning about the NAT single point of failure."
  value       = "One t4g.nano serves every private subnet. If it is replaced, the private default route points at a stale ENI until the next apply. Re-apply after any NAT instance replacement."
}

output "flow_log_group_name" {
  description = "CloudWatch log group receiving flow logs, or null when disabled."
  value       = one(aws_cloudwatch_log_group.flow_logs[*].name)
}