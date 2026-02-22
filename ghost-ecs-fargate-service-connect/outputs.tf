output "alb_dns_name" {
  description = "Public DNS name for the ALB"
  value       = aws_lb.ghost.dns_name
}

output "alb_target_group_arn" {
  description = "ALB target group ARN for Ghost"
  value       = aws_lb_target_group.ghost.arn
}

output "db_endpoint" {
  description = "Aurora cluster endpoint"
  value       = aws_rds_cluster.ghost.endpoint
}

output "ghost_url" {
  description = "Ghost URL configured in the container"
  value       = local.ghost_url
}

