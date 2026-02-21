# -------------------------------------------------------
# IAM — shared task execution role
# -------------------------------------------------------
resource "aws_iam_role" "task_execution" {
  name = "${local.name_prefix}-task-exec"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "task_execution_secrets" {
  name = "${local.name_prefix}-task-exec-secrets"
  role = aws_iam_role.task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = [aws_secretsmanager_secret.db.arn]
      }
    ]
  })
}

# -------------------------------------------------------
# CloudWatch log groups — one per service
# -------------------------------------------------------
resource "aws_cloudwatch_log_group" "ghost" {
  name              = "/ecs/${local.name_prefix}"
  retention_in_days = 14
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "webhook" {
  name              = "/ecs/${local.name_prefix}-webhook"
  retention_in_days = 7
  tags              = local.tags
}

# -------------------------------------------------------
# ECS cluster — shared by both services
# -------------------------------------------------------
resource "aws_ecs_cluster" "ghost" {
  name = "${local.name_prefix}-cluster"
  tags = local.tags
}

# =======================================================
# Ghost — task definition + service
# =======================================================
resource "aws_ecs_task_definition" "ghost" {
  family                   = "${local.name_prefix}-ghost"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.ghost_cpu
  memory                   = var.ghost_memory
  execution_role_arn       = aws_iam_role.task_execution.arn

  container_definitions = jsonencode([
    {
      name      = "ghost"
      image     = "ghost:6.1.0"
      essential = true
      portMappings = [
        {
          containerPort = 2368
          hostPort      = 2368
          protocol      = "tcp"
        }
      ]
      environment = [
        {
          name  = "url"
          value = local.ghost_url
        },
        {
          name  = "database__client"
          value = "mysql"
        },
        {
          name  = "database__connection__host"
          value = aws_rds_cluster.ghost.endpoint
        },
        {
          name  = "database__connection__port"
          value = "3306"
        },
        {
          name  = "database__connection__user"
          value = var.db_username
        },
        {
          name  = "database__connection__database"
          value = var.db_name
        },
        {
          name  = "logging__level"
          value = "info"
        }
      ]
      secrets = [
        {
          name      = "database__connection__password"
          valueFrom = "${aws_secretsmanager_secret.db.arn}:password::"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ghost.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ghost"
        }
      }
    }
  ])

  tags = local.tags
}

resource "aws_ecs_service" "ghost" {
  name            = "${local.name_prefix}-ghost"
  cluster         = aws_ecs_cluster.ghost.id
  task_definition = aws_ecs_task_definition.ghost.arn
  desired_count   = var.ecs_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.ghost.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.ghost.arn
    container_name   = "ghost"
    container_port   = 2368
  }

  depends_on = [
    aws_lb_listener.http,
    aws_rds_cluster_instance.ghost
  ]

  tags = local.tags
}

# =======================================================
# Webhook receiver — task definition + service
# =======================================================
resource "aws_ecs_task_definition" "webhook" {
  family                   = "${local.name_prefix}-webhook"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.webhook_cpu
  memory                   = var.webhook_memory
  execution_role_arn       = aws_iam_role.task_execution.arn

  container_definitions = jsonencode([
    {
      name      = "webhook-receiver"
      image     = "${aws_ecr_repository.webhook.repository_url}:latest"
      essential = true
      portMappings = [
        {
          containerPort = 8000
          hostPort      = 8000
          protocol      = "tcp"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.webhook.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "webhook"
        }
      }
    }
  ])

  tags = local.tags
}

resource "aws_ecs_service" "webhook" {
  name            = "${local.name_prefix}-webhook"
  cluster         = aws_ecs_cluster.ghost.id
  task_definition = aws_ecs_task_definition.webhook.arn
  desired_count   = var.ecs_desired_count
  launch_type     = "ECSs"

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.webhook.id]
    assign_public_ip = false
  }

  tags = local.tags
}
