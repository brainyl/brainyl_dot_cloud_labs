# Application Load Balancer using community module
module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 9.0"

  name = "${var.name_prefix}-alb"

  load_balancer_type = "application"

  vpc_id          = var.vpc_id
  subnets         = var.public_subnet_ids
  security_groups = [var.alb_security_group_id]

  enable_deletion_protection = false

  # HTTP listener (HTTPS can be added later with certificate)
  listeners = {
    http = {
      port     = 80
      protocol = "HTTP"
      forward = {
        target_group_key = "frontend"
      }
    }
  }

  # Target Groups - only frontend
  target_groups = {
    frontend = {
      name_prefix          = "fe-"
      backend_protocol     = "HTTP"
      backend_port         = 80
      target_type          = "ip"
      create_attachment    = false  # ECS will register targets
      
      deregistration_delay = var.deregistration_delay
      
      health_check = {
        enabled             = true
        interval            = var.health_check_interval
        path                = "/health"
        port                = "traffic-port"
        healthy_threshold   = var.healthy_threshold
        unhealthy_threshold = var.unhealthy_threshold
        timeout             = var.health_check_timeout
        protocol            = "HTTP"
        matcher             = "200"
      }
    }
  }

  tags = {
    Name = "${var.name_prefix}-alb"
  }
}
