output "nat_instance_ids" {
  description = "List of NAT instance IDs"
  value       = aws_instance.this[*].id
}

output "nat_instance_public_ips" {
  description = "List of NAT instance Elastic IP addresses"
  value       = aws_eip.this[*].public_ip
}

output "nat_instance_private_ips" {
  description = "List of NAT instance private IP addresses"
  value       = aws_instance.this[*].private_ip
}

output "nat_instance_network_interface_ids" {
  description = "List of NAT instance primary network interface IDs"
  value       = aws_instance.this[*].primary_network_interface_id
}

output "security_group_id" {
  description = "Security group ID for NAT instances"
  value       = try(aws_security_group.this[0].id, null)
}