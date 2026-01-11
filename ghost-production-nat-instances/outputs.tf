output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.this.id
}

output "nat_instance_ids" {
  description = "NAT instance IDs"
  value       = module.nat_instances.nat_instance_ids
}

output "nat_instance_public_ips" {
  description = "NAT instance Elastic IP addresses"
  value       = module.nat_instances.nat_instance_public_ips
}

output "alb_dns_name" {
  description = "ALB DNS name"
  value       = module.alb.dns_name
}

output "aurora_endpoint" {
  description = "Aurora cluster endpoint"
  value       = module.aurora.cluster_endpoint
}

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain name"
  value       = module.cloudfront.cloudfront_distribution_domain_name
}

output "domain_name" {
  description = "Domain name pointing to CloudFront"
  value       = var.domain_name
}