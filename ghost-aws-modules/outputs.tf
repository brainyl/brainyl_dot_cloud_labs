output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
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

output "cloudfront_id" {
  description = "CloudFront distribution ID"
  value       = module.cloudfront.cloudfront_distribution_id
}

output "acm_certificate_arn_cloudfront" {
  description = "ACM certificate ARN for CloudFront (us-east-1)"
  value       = module.acm_cloudfront.acm_certificate_arn
}

output "acm_certificate_arn_alb" {
  description = "ACM certificate ARN for ALB (us-west-2)"
  value       = module.acm_alb.acm_certificate_arn
}

output "acm_certificate_validation_domains" {
  description = "ACM certificate validation DNS records. Create these DNS records to validate the certificate."
  value       = module.acm_cloudfront.validation_domains
}

output "acm_certificate_status_cloudfront" {
  description = "ACM certificate status for CloudFront"
  value       = module.acm_cloudfront.acm_certificate_status
}

output "acm_certificate_status_alb" {
  description = "ACM certificate status for ALB"
  value       = module.acm_alb.acm_certificate_status
}

output "db_master_user_secret_arn" {
  description = "ARN of the Secrets Manager secret containing the database master password"
  value       = module.aurora.cluster_master_user_secret[0].secret_arn
}

output "db_master_username" {
  description = "Database master username"
  value       = var.db_master_username
}

output "db_name" {
  description = "Database name"
  value       = var.db_name
}

output "domain_name" {
  description = "Domain name pointing to CloudFront"
  value       = var.domain_name
}

output "route53_record_fqdn" {
  description = "Route53 record FQDN (if Route53 zone was provided)"
  value       = local.has_route53_zone ? aws_route53_record.cloudfront[0].fqdn : "No Route53 zone provided"
}

