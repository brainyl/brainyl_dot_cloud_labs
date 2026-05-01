output "vpc_id" {
  description = "ID of the VPC"
  value       = module.networking.vpc_id
}

output "public_subnet_ids" {
  description = "IDs of public subnets"
  value       = module.networking.public_subnet_ids
}

output "private_subnet_ids" {
  description = "IDs of private subnets"
  value       = module.networking.private_subnet_ids
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = module.alb.alb_dns_name
}

output "alb_zone_id" {
  description = "Zone ID of the Application Load Balancer"
  value       = module.alb.alb_zone_id
}

output "ecr_repository_urls" {
  description = "URLs of ECR repositories (from bootstrap)"
  value       = local.ecr_repository_urls
}

output "bootstrap_outputs" {
  description = "All outputs from bootstrap module"
  value = {
    mysql_root_password_secret_arn = data.terraform_remote_state.bootstrap.outputs.mysql_root_password_secret_arn
    mysql_app_password_secret_arn  = data.terraform_remote_state.bootstrap.outputs.mysql_app_password_secret_arn
    appconfig_application_id       = data.terraform_remote_state.bootstrap.outputs.appconfig_application_id
    appconfig_environment_id       = data.terraform_remote_state.bootstrap.outputs.appconfig_environment_id
    appconfig_profile_id           = data.terraform_remote_state.bootstrap.outputs.appconfig_profile_id
  }
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster"
  value       = module.ecs_cluster.cluster_name
}

output "ecs_cluster_arn" {
  description = "ARN of the ECS cluster"
  value       = module.ecs_cluster.cluster_arn
}

output "service_connect_namespace" {
  description = "ECS Service Connect namespace"
  value       = "${local.name_prefix}.local"
}

output "task_execution_role_arn" {
  description = "ARN of the ECS task execution role"
  value       = module.iam.task_execution_role_arn
}

output "task_role_arn" {
  description = "ARN of the ECS task role"
  value       = module.iam.task_role_arn
}

output "mysql_service_name" {
  description = "Name of the MySQL ECS service"
  value       = module.mysql_service.service_name
}

output "backend_service_name" {
  description = "Name of the Backend ECS service"
  value       = module.backend_service.service_name
}

output "frontend_service_name" {
  description = "Name of the Frontend ECS service"
  value       = module.frontend_service.service_name
}

output "cloudwatch_log_groups" {
  description = "CloudWatch log group names"
  value = {
    mysql    = "/ecs/${var.project_name}-${var.environment}/mysql"
    backend  = "/ecs/${var.project_name}-${var.environment}/backend"
    frontend = "/ecs/${var.project_name}-${var.environment}/frontend"
  }
}

# Helpful commands
output "helpful_commands" {
  description = "Helpful commands for managing the infrastructure"
  value = <<-EOT
    # View logs
    aws logs tail /ecs/${var.project_name}-${var.environment}/mysql --follow
    aws logs tail /ecs/${var.project_name}-${var.environment}/backend --follow
    aws logs tail /ecs/${var.project_name}-${var.environment}/frontend --follow
    
    # List ECS services
    aws ecs list-services --cluster ${module.ecs_cluster.cluster_name}
    
    # Describe service
    aws ecs describe-services --cluster ${module.ecs_cluster.cluster_name} --services mysql-service
    
    # Execute command in container (ECS Exec)
    aws ecs execute-command --cluster ${module.ecs_cluster.cluster_name} \
      --task <task-id> --container mysql --interactive --command "/bin/bash"
    
    # Access application
    echo "Frontend: http://${module.alb.alb_dns_name}"
    echo "Backend API: http://${module.alb.alb_dns_name}/api"
  EOT
}
