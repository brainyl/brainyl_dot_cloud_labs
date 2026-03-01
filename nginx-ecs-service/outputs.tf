output "alb_dns_name" {
  description = "Public DNS name for the ALB"
  value       = aws_lb.nginx.dns_name
}

output "alb_target_group_arn" {
  description = "ALB target group ARN for nginx"
  value       = aws_lb_target_group.blue_nginx_tg.arn
}
