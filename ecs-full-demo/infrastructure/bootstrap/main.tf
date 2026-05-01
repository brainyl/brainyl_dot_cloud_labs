terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
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
      Layer       = "Bootstrap"
    }
  }
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

# Random passwords for MySQL
resource "random_password" "mysql_root" {
  length  = 32
  special = true
}

resource "random_password" "mysql_app" {
  length  = 32
  special = true
}

# Secrets Manager - MySQL Root Password
resource "aws_secretsmanager_secret" "mysql_root_password" {
  name_prefix             = "mysql/${var.project_name}/root-password-"
  description             = "MySQL root password for ${var.project_name}"
  recovery_window_in_days = 7

  tags = {
    Name = "${local.name_prefix}-mysql-root-password"
  }
}

resource "aws_secretsmanager_secret_version" "mysql_root_password" {
  secret_id     = aws_secretsmanager_secret.mysql_root_password.id
  secret_string = random_password.mysql_root.result

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# Secrets Manager - MySQL App User Password
resource "aws_secretsmanager_secret" "mysql_app_password" {
  name_prefix             = "mysql/${var.project_name}/app-password-"
  description             = "MySQL application user password for ${var.project_name}"
  recovery_window_in_days = 7

  tags = {
    Name = "${local.name_prefix}-mysql-app-password"
  }
}

resource "aws_secretsmanager_secret_version" "mysql_app_password" {
  secret_id     = aws_secretsmanager_secret.mysql_app_password.id
  secret_string = random_password.mysql_app.result

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ECR Repositories
module "ecr" {
  source  = "terraform-aws-modules/ecr/aws"
  version = "~> 2.0"

  for_each = toset(var.ecr_repositories)

  repository_name = "${local.name_prefix}-${each.value}"

  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "latest"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Remove untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      }
    ]
  })

  repository_image_tag_mutability = "MUTABLE"
  repository_image_scan_on_push   = true
  repository_encryption_type      = "AES256"

  tags = {
    Service = each.value
  }
}

# AppConfig Application
resource "aws_appconfig_application" "main" {
  name        = "${local.name_prefix}-deployments"
  description = "Deployment manifests for ${var.project_name} ECS services"

  tags = {
    Name = "${local.name_prefix}-appconfig"
  }
}

# AppConfig Environment
resource "aws_appconfig_environment" "main" {
  application_id = aws_appconfig_application.main.id
  name           = var.environment
  description    = "${title(var.environment)} environment for deployment manifests"

  tags = {
    Name = "${local.name_prefix}-appconfig-env"
  }
}

# AppConfig Configuration Profile (Hosted)
resource "aws_appconfig_configuration_profile" "deployment_manifest" {
  application_id = aws_appconfig_application.main.id
  name           = "deployment-manifest"
  description    = "Deployment manifest configuration"
  location_uri   = "hosted"
  type           = "AWS.Freeform"

  tags = {
    Name = "${local.name_prefix}-appconfig-profile"
  }
}

# AppConfig Deployment Strategy (Immediate)
resource "aws_appconfig_deployment_strategy" "immediate" {
  name                           = "${local.name_prefix}-immediate"
  description                    = "Deploy configuration immediately"
  deployment_duration_in_minutes = 0
  growth_factor                  = 100
  replicate_to                   = "NONE"
  final_bake_time_in_minutes     = 0

  tags = {
    Name = "${local.name_prefix}-appconfig-strategy"
  }
}

# Initial AppConfig Hosted Configuration (Version 0)
# This creates a baseline manifest that will be updated by CI/CD
resource "aws_appconfig_hosted_configuration_version" "initial" {
  application_id           = aws_appconfig_application.main.id
  configuration_profile_id = aws_appconfig_configuration_profile.deployment_manifest.configuration_profile_id
  content_type             = "application/json"
  description              = "Initial baseline configuration (version 0)"

  content = jsonencode({
    version   = "1.0"
    timestamp = timestamp()
    commit    = "bootstrap"
    branch    = "main"
    services = {
      mysql = {
        service   = "mysql"
        image     = "${module.ecr["mysql"].repository_url}:latest"
        imageTag  = "latest"
        timestamp = timestamp()
        commit    = "bootstrap"
        resources = {
          cpu    = "512"
          memory = "1024"
        }
        environment = {
          MYSQL_DATABASE = "simpledb"
          MYSQL_USER     = "appuser"
        }
      }
      backend = {
        service   = "backend"
        image     = "${module.ecr["backend"].repository_url}:latest"
        imageTag  = "latest"
        timestamp = timestamp()
        commit    = "bootstrap"
        resources = {
          cpu    = "256"
          memory = "512"
        }
        environment = {
          DB_USERNAME = "appuser"
          DB_HOST     = "mysql"
          DB_PORT     = "3306"
          DB_NAME     = "simpledb"
        }
      }
      frontend = {
        service   = "frontend"
        image     = "${module.ecr["frontend"].repository_url}:latest"
        imageTag  = "latest"
        timestamp = timestamp()
        commit    = "bootstrap"
        resources = {
          cpu    = "256"
          memory = "512"
        }
        environment = {
          ALLOW_DELETE = "true"
        }
      }
    }
  })

  # Don't recreate on every apply - only create once
  lifecycle {
    ignore_changes = [content, description]
  }
}

# Optional: Create initial deployment to make config immediately available
# This deploys version 0 to the environment
resource "aws_appconfig_deployment" "initial" {
  application_id           = aws_appconfig_application.main.id
  environment_id           = aws_appconfig_environment.main.environment_id
  configuration_profile_id = aws_appconfig_configuration_profile.deployment_manifest.configuration_profile_id
  configuration_version    = aws_appconfig_hosted_configuration_version.initial.version_number
  deployment_strategy_id   = aws_appconfig_deployment_strategy.immediate.id
  description              = "Initial deployment of baseline configuration"

  tags = {
    Name = "${local.name_prefix}-initial-deployment"
  }
}
