locals {
  name_prefix = var.project_name
  app_url   = var.app_url != "" ? var.app_url : "http://${aws_lb.app.dns_name}"
  tags = {
    Project = var.project_name
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.19.0"

  name = "${local.name_prefix}-vpc"
  cidr = "10.10.0.0/16"

  azs             = ["${var.aws_region}a", "${var.aws_region}b"]
  public_subnets  = ["10.10.10.0/24", "10.10.11.0/24"]
  private_subnets = ["10.10.20.0/24", "10.10.21.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = local.tags
}

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "ALB access"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

resource "aws_security_group" "ecs" {
  name        = "${local.name_prefix}-ecs-sg"
  description = "ECS tasks"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

resource "aws_lb" "app" {
  name               = "${local.name_prefix}-alb"
  load_balancer_type = "application"
  subnets            = module.vpc.public_subnets
  security_groups    = [aws_security_group.alb.id]
  tags               = local.tags
}

resource "aws_lb_target_group" "blue_app_tg" {
  name        = "${local.name_prefix}-blue-tg"
  port        = 8000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = module.vpc.vpc_id

  health_check {
    path                = "/"
    matcher             = "200-399"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = local.tags
}

resource "aws_lb_listener" "blue_http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.green_app_tg.arn
  }
}

resource "aws_lb_target_group" "green_app_tg" {
  name        = "${local.name_prefix}-green-tg"
  port        = 8000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = module.vpc.vpc_id

  health_check {
    path                = "/"
    matcher             = "200-399"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = local.tags
}

# Test listener (port 8080) - forwards to green TG for validating before production shift
resource "aws_lb_listener" "green_http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 8080
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.green_app_tg.arn
  }
}

# Test listener rule - ECS modifies this during blue/green deployment
resource "aws_lb_listener_rule" "test" {
  listener_arn = aws_lb_listener.green_http.arn
  priority     = 1

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.green_app_tg.arn
  }

  condition {
    path_pattern {
      values = ["/", "/*"]
    }
  }
}

# Production listener rule - ECS modifies this during blue/green deployment
resource "aws_lb_listener_rule" "production" {
  listener_arn = aws_lb_listener.blue_http.arn
  priority     = 1

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.blue_app_tg.arn
  }

  condition {
    path_pattern {
      values = ["/", "/*"]
    }
  }
}