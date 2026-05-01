output "alb_arn" {
  description = "ARN of the ALB"
  value       = module.alb.arn
}

output "alb_dns_name" {
  description = "DNS name of the ALB"
  value       = module.alb.dns_name
}

output "alb_zone_id" {
  description = "Zone ID of the ALB"
  value       = module.alb.zone_id
}

output "frontend_target_group_arn" {
  description = "ARN of the frontend target group"
  value       = module.alb.target_groups["frontend"].arn
}
