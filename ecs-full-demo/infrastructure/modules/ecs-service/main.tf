# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "main" {
  name              = "/ecs/${var.name_prefix}/${var.service_name}"
  retention_in_days = 7

  tags = {
    Name    = "${var.name_prefix}-${var.service_name}-logs"
    Service = var.service_name
  }
}

# ECS Task Definition
resource "aws_ecs_task_definition" "main" {
  family                   = "${var.name_prefix}-${var.service_name}"
  network_mode             = "awsvpc"  # Always use awsvpc for Service Connect
  requires_compatibilities = var.requires_compatibilities != null ? var.requires_compatibilities : [var.launch_type]
  cpu                      = var.launch_type == "FARGATE" ? var.cpu : null
  memory                   = var.launch_type == "FARGATE" ? var.memory : null
  execution_role_arn       = var.task_execution_role_arn
  task_role_arn            = var.task_role_arn

  # Runtime platform (Fargate only)
  dynamic "runtime_platform" {
    for_each = var.launch_type == "FARGATE" ? [1] : []
    content {
      operating_system_family = "LINUX"
      cpu_architecture        = "X86_64"  # AMD64 - Fargate default
    }
  }

  # Container definitions
  container_definitions = jsonencode([
    {
      name      = var.service_name
      image     = var.container_image
      essential = true
      cpu       = var.launch_type == "EC2" ? var.cpu : null
      memory    = var.launch_type == "EC2" ? var.memory : null

      portMappings = concat(
        [
          {
            name          = var.service_name
            containerPort = var.container_port
            protocol      = "tcp"
            appProtocol   = var.enable_service_connect ? var.service_connect_app_protocol : null
          }
        ],
        []
      )

      environment = [
        for key, value in var.environment_variables : {
          name  = key
          value = value
        }
      ]

      secrets = var.secrets

      healthCheck = var.health_check

      mountPoints = var.mount_points

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.main.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = var.service_name
        }
      }
    }
  ])

  # Volumes (for EFS or host paths)
  dynamic "volume" {
    for_each = var.volumes
    content {
      name      = volume.value.name
      host_path = try(volume.value.host_path, null)

      dynamic "efs_volume_configuration" {
        for_each = volume.value.efs_volume_configuration != null ? [volume.value.efs_volume_configuration] : []
        content {
          file_system_id          = efs_volume_configuration.value.file_system_id
          transit_encryption      = efs_volume_configuration.value.transit_encryption
          transit_encryption_port = efs_volume_configuration.value.transit_encryption_port

          dynamic "authorization_config" {
            for_each = efs_volume_configuration.value.authorization_config != null ? [efs_volume_configuration.value.authorization_config] : []
            content {
              access_point_id = try(authorization_config.value.access_point_id, null)
              iam             = try(authorization_config.value.iam, null)
            }
          }
        }
      }
    }
  }

  # Lifecycle: Let deployment workflow manage container definitions
  # Terraform manages infrastructure (volumes, IAM, networking, secrets)
  # AppConfig/Deployment workflow manages application (image, environment variables)
  # 
  # Why ignore_changes?
  # - Prevents Terraform from overwriting CI/CD deployments
  # - CI/CD updates: image tags, environment variables
  # - Terraform updates: secrets, volumes, IAM roles
  # 
  # When secrets change:
  # - Update Terraform configuration
  # - Run: ../scripts/apply-secret-changes.sh
  # - This applies Terraform changes and forces ECS redeployment
  lifecycle {
    ignore_changes = [
      container_definitions,  # Deployment workflow updates these
    ]
  }

  tags = {
    Name    = "${var.name_prefix}-${var.service_name}-task"
    Service = var.service_name
  }
}

# Service Discovery Service (Legacy - only if not using Service Connect)
resource "aws_service_discovery_service" "main" {
  count = var.enable_service_discovery && !var.enable_service_connect ? 1 : 0

  name = var.service_name

  dns_config {
    namespace_id = var.service_discovery_namespace_id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }

  tags = {
    Name    = "${var.name_prefix}-${var.service_name}-discovery"
    Service = var.service_name
  }
}

# ECS Service
resource "aws_ecs_service" "main" {
  name            = "${var.name_prefix}-${var.service_name}"
  cluster         = var.cluster_id
  task_definition = aws_ecs_task_definition.main.arn
  desired_count   = var.desired_count
  launch_type     = var.launch_type == "EC2" ? null : var.launch_type

  # Capacity provider strategy for EC2
  dynamic "capacity_provider_strategy" {
    for_each = var.launch_type == "EC2" ? [1] : []
    content {
      capacity_provider = var.capacity_provider_name
      weight            = 1
      base              = 1
    }
  }

  # Network configuration (awsvpc mode - required for Service Connect)
  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = false
  }

  # Placement constraints
  dynamic "placement_constraints" {
    for_each = var.placement_constraints
    content {
      type       = placement_constraints.value.type
      expression = try(placement_constraints.value.expression, null)
    }
  }

  # Load balancer configuration
  dynamic "load_balancer" {
    for_each = var.enable_load_balancer ? [1] : []
    content {
      target_group_arn = var.target_group_arn
      container_name   = var.service_name
      container_port   = var.container_port
    }
  }

  # Service discovery configuration (Legacy Cloud Map)
  dynamic "service_registries" {
    for_each = var.enable_service_discovery && !var.enable_service_connect ? [1] : []
    content {
      registry_arn = aws_service_discovery_service.main[0].arn
    }
  }

  # Service Connect configuration (Modern approach)
  dynamic "service_connect_configuration" {
    for_each = var.enable_service_connect ? [1] : []
    content {
      enabled   = true
      namespace = var.service_connect_namespace

      dynamic "service" {
        for_each = var.service_connect_client_only ? [] : [1]
        content {
          port_name      = var.service_name
          discovery_name = var.service_name

          client_alias {
            port     = var.container_port
            dns_name = var.service_name
          }
        }
      }

      log_configuration {
        log_driver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.main.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "service-connect"
        }
      }
    }
  }

  # Enable ECS Exec
  enable_execute_command = true

  # Deployment configuration
  deployment_maximum_percent         = var.deployment_maximum_percent
  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent

  # Terraform creates the service pointing at the initial task definition revision.
  # CI/CD (AppConfig deploy workflow) then registers newer revisions and updates
  # the service independently. Ignoring task_definition prevents Terraform from
  # rolling the service back to the last Terraform-managed revision on every apply.
  lifecycle {
    ignore_changes = [task_definition]
  }

  # Wait for load balancer to be ready before creating service
  depends_on = [
    aws_cloudwatch_log_group.main
  ]

  tags = {
    Name    = "${var.name_prefix}-${var.service_name}-service"
    Service = var.service_name
  }
}

# Auto Scaling Target
resource "aws_appautoscaling_target" "main" {
  count = var.enable_autoscaling ? 1 : 0

  max_capacity       = var.max_capacity
  min_capacity       = var.min_capacity
  resource_id        = "service/${var.cluster_name}/${aws_ecs_service.main.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

# Auto Scaling Policy - CPU
resource "aws_appautoscaling_policy" "cpu" {
  count = var.enable_autoscaling ? 1 : 0

  name               = "${var.name_prefix}-${var.service_name}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.main[0].resource_id
  scalable_dimension = aws_appautoscaling_target.main[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.main[0].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = var.cpu_target_value
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

# Auto Scaling Policy - Memory
resource "aws_appautoscaling_policy" "memory" {
  count = var.enable_autoscaling ? 1 : 0

  name               = "${var.name_prefix}-${var.service_name}-memory-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.main[0].resource_id
  scalable_dimension = aws_appautoscaling_target.main[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.main[0].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    target_value       = var.memory_target_value
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

# Data source for current region
data "aws_region" "current" {}
