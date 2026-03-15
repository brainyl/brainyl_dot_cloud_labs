output "alb_dns_name" {
  description = "Public DNS name for the ALB"
  value       = aws_lb.app.dns_name
}

output "alb_target_group_arn" {
  description = "ALB target group ARN for app"
  value       = aws_lb_target_group.blue_app_tg.arn
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.app.name
}
output "ecs_service_name" {
  value = aws_ecs_service.app.name
}