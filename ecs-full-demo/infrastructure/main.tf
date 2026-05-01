terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

# Data source to reference bootstrap outputs
data "terraform_remote_state" "bootstrap" {
  backend = "local"

  config = {
    path = "${path.module}/bootstrap/terraform.tfstate"
  }
}

# Data sources
data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  azs         = slice(data.aws_availability_zones.available.names, 0, 2)
  
  # Reference bootstrap outputs
  ecr_repository_urls             = data.terraform_remote_state.bootstrap.outputs.ecr_repository_urls
  mysql_root_password_secret_arn  = data.terraform_remote_state.bootstrap.outputs.mysql_root_password_secret_arn
  mysql_app_password_secret_arn   = data.terraform_remote_state.bootstrap.outputs.mysql_app_password_secret_arn
}

# 1. Networking - VPC, Subnets, Security Groups
module "networking" {
  source = "./modules/networking"

  name_prefix         = local.name_prefix
  vpc_cidr            = var.vpc_cidr
  availability_zones  = local.azs
  enable_nat_gateway  = var.enable_nat_gateway
}

# Note: ECR repositories are created in bootstrap module
# No ECR module here - services reference bootstrap outputs

# 2. ECS Cluster
module "ecs_cluster" {
  source = "./modules/ecs-cluster"

  name_prefix = local.name_prefix
}

# 3. IAM Roles
module "iam" {
  source = "./modules/iam"

  name_prefix = local.name_prefix
  aws_region  = var.aws_region
  account_id  = data.aws_caller_identity.current.account_id
}

# 4. Application Load Balancer
module "alb" {
  source = "./modules/alb"

  name_prefix             = local.name_prefix
  vpc_id                  = module.networking.vpc_id
  public_subnet_ids       = module.networking.public_subnet_ids
  alb_security_group_id   = module.networking.alb_security_group_id
  certificate_arn         = var.certificate_arn
  deregistration_delay    = var.alb_deregistration_delay
  health_check_interval   = var.alb_health_check_interval
  health_check_timeout    = var.alb_health_check_timeout
  healthy_threshold       = var.alb_healthy_threshold
  unhealthy_threshold     = var.alb_unhealthy_threshold
}

# 6. ECS EC2 Capacity Provider for MySQL
module "ecs_ec2" {
  source = "./modules/ecs-ec2"

  name_prefix                     = local.name_prefix
  cluster_name                    = module.ecs_cluster.cluster_name
  vpc_id                          = module.networking.vpc_id
  private_subnet_ids              = module.networking.private_subnet_ids
  ecs_instance_security_group_id  = module.networking.ecs_instance_security_group_id
  instance_type                   = "t3.small"
  desired_capacity                = 1
  min_size                        = 1
  max_size                        = 1
  mysql_volume_size               = 20
}

# Attach capacity provider to cluster
resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name = module.ecs_cluster.cluster_name

  capacity_providers = [
    "FARGATE",
    "FARGATE_SPOT",
    module.ecs_ec2.capacity_provider_name
  ]

  # Default strategy - services can override this
  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
}

# Note: Service Connect is configured at cluster level
# No separate service discovery module needed

# 7. MySQL Service (EC2 Launch Type with EBS)
# Note: Task definition container_definitions are managed by deployment workflow
# Terraform manages: infrastructure (volumes, IAM, networking, Service Connect)
# Workflow manages: application (image tags, env vars, secrets, health checks)
module "mysql_service" {
  source = "./modules/ecs-service"

  name_prefix                = local.name_prefix
  service_name               = "mysql"
  cluster_id                 = module.ecs_cluster.cluster_id
  cluster_name               = module.ecs_cluster.cluster_name
  vpc_id                     = module.networking.vpc_id
  private_subnet_ids         = module.networking.private_subnet_ids
  security_group_ids         = [module.networking.mysql_security_group_id]
  task_execution_role_arn    = module.iam.task_execution_role_arn
  task_role_arn              = module.iam.task_role_arn
  
  # Container configuration - references bootstrap ECR
  container_image            = "${local.ecr_repository_urls["mysql"]}:latest"
  container_port             = 3306
  cpu                        = var.mysql_cpu
  memory                     = var.mysql_memory
  
  # Environment variables - managed by AppConfig manifest
  # Terraform only manages infrastructure, not application config
  environment_variables = {}
  
  # Secrets - managed by Terraform
  secrets = [
    {
      name      = "MYSQL_ROOT_PASSWORD"
      valueFrom = local.mysql_root_password_secret_arn
    },
    {
      name      = "MYSQL_PASSWORD"
      valueFrom = local.mysql_app_password_secret_arn
    }
  ]
  
  # Health check
  health_check = {
    command     = ["CMD-SHELL", "mysqladmin ping -h localhost -u root -p$MYSQL_ROOT_PASSWORD || exit 1"]
    interval    = 30
    timeout     = 5
    retries     = 3
    startPeriod = 60
  }
  
  # EC2 launch type
  launch_type                = "EC2"
  requires_compatibilities   = ["EC2"]
  capacity_provider_name     = module.ecs_ec2.capacity_provider_name
  
  # Host volume for EBS (mounted at /mnt/mysql-data by user_data script)
  volumes = [
    {
      name      = "mysql-data"
      host_path = "/mnt/mysql-data"
    }
  ]
  
  mount_points = [
    {
      sourceVolume  = "mysql-data"
      containerPath = "/var/lib/mysql"
      readOnly      = false
    }
  ]
  
  # Service Connect - expose MySQL endpoint
  enable_service_connect       = true
  service_connect_namespace    = module.ecs_cluster.service_connect_namespace_arn
  service_connect_client_only  = false
  # null = raw TCP — no HTTP-level Envoy inspection (correct for MySQL binary protocol).
  # If the service was originally created with "http", it must be destroyed and
  # recreated for this to take effect (AWS does not allow in-place changes).
  service_connect_app_protocol = null
  
  # Single task for MySQL (no auto-scaling)
  desired_count = 1

  # Stop-old-before-start-new: MySQL uses a host-path EBS volume that only one
  # container can hold at a time. max=100% stops the running task first;
  # min=0% allows a brief gap while the new task initialises.
  deployment_maximum_percent         = 100
  deployment_minimum_healthy_percent = 0

  # No load balancer for MySQL
  enable_load_balancer = false
}

# 7. Backend Service
# Note: Task definition container_definitions are managed by deployment workflow
module "backend_service" {
  source = "./modules/ecs-service"

  name_prefix                = local.name_prefix
  service_name               = "backend"
  cluster_id                 = module.ecs_cluster.cluster_id
  cluster_name               = module.ecs_cluster.cluster_name
  vpc_id                     = module.networking.vpc_id
  private_subnet_ids         = module.networking.private_subnet_ids
  security_group_ids         = [module.networking.backend_security_group_id]
  task_execution_role_arn    = module.iam.task_execution_role_arn
  task_role_arn              = module.iam.task_role_arn
  
  # Container configuration - references bootstrap ECR
  container_image            = "${local.ecr_repository_urls["backend"]}:latest"
  container_port             = 8000
  cpu                        = var.backend_cpu
  memory                     = var.backend_memory
  
  # Environment variables - managed by AppConfig manifest
  # Terraform only manages infrastructure, not application config
  environment_variables = {}
  
  # Secrets - managed by Terraform
  secrets = [
    {
      name      = "DB_PASSWORD"
      valueFrom = local.mysql_app_password_secret_arn
    }
  ]
  
  # Health check
  health_check = {
    command     = ["CMD-SHELL", "curl -f http://localhost:8000/ || exit 1"]
    interval    = 30
    timeout     = 5
    retries     = 3
    startPeriod = 10
  }
  
  # Service Connect - expose backend endpoint and connect to mysql
  enable_service_connect     = true
  service_connect_namespace  = module.ecs_cluster.service_connect_namespace_arn
  service_connect_client_only = false
  
  # No load balancer for backend - only accessible via Service Connect
  enable_load_balancer = false
  
  # Auto-scaling
  desired_count = 2
  
  # Depends on MySQL
  depends_on = [module.mysql_service]
}

# 8. Frontend Service
# Note: Task definition container_definitions are managed by deployment workflow
module "frontend_service" {
  source = "./modules/ecs-service"

  name_prefix                = local.name_prefix
  service_name               = "frontend"
  cluster_id                 = module.ecs_cluster.cluster_id
  cluster_name               = module.ecs_cluster.cluster_name
  vpc_id                     = module.networking.vpc_id
  private_subnet_ids         = module.networking.private_subnet_ids  # Frontend in private subnets with NAT
  security_group_ids         = [module.networking.frontend_security_group_id]
  task_execution_role_arn    = module.iam.task_execution_role_arn
  task_role_arn              = module.iam.task_role_arn
  
  # Container configuration - references bootstrap ECR
  container_image            = "${local.ecr_repository_urls["frontend"]}:latest"
  container_port             = 80
  cpu                        = var.frontend_cpu
  memory                     = var.frontend_memory
  
  # No environment variables or secrets needed for frontend
  environment_variables = {}
  secrets               = []
  
  # Health check
  health_check = {
    command     = ["CMD-SHELL", "curl -f http://localhost/health || exit 1"]
    interval    = 30
    timeout     = 5
    retries     = 3
    startPeriod = 10
  }
  
  # Service Connect - client only (connects to backend)
  enable_service_connect      = true
  service_connect_namespace   = module.ecs_cluster.service_connect_namespace_arn
  service_connect_client_only = false  # Frontend also exposes endpoint for ALB
  
  # Load balancer
  enable_load_balancer = true
  target_group_arn     = module.alb.frontend_target_group_arn
  
  # Auto-scaling
  desired_count = 2
  
  # Depends on Backend
  depends_on = [module.backend_service]
}
