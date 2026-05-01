output "vpc_id" {
  description = "ID of the VPC"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "IDs of public subnets"
  value       = module.vpc.public_subnets
}

output "private_subnet_ids" {
  description = "IDs of private subnets"
  value       = module.vpc.private_subnets
}

output "alb_security_group_id" {
  description = "ID of ALB security group"
  value       = aws_security_group.alb.id
}

output "frontend_security_group_id" {
  description = "ID of Frontend security group"
  value       = aws_security_group.frontend.id
}

output "backend_security_group_id" {
  description = "ID of Backend security group"
  value       = aws_security_group.backend.id
}

output "mysql_security_group_id" {
  description = "ID of MySQL security group"
  value       = aws_security_group.mysql.id
}

output "efs_security_group_id" {
  description = "ID of EFS security group"
  value       = aws_security_group.efs.id
}
output "ecs_instance_security_group_id" {
  description = "ID of ECS instance security group"
  value       = aws_security_group.ecs_instance.id
}
