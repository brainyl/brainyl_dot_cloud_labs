// service/main.tf
terraform {
  required_version = ">= 1.13.4"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.20.0"
    }
  }
}

provider "aws" {
  region = var.region
}

module "service_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.5.0"

  name = "service"
  cidr = var.cidr

  azs             = var.azs
  public_subnets  = [for i in range(length(var.azs)) : cidrsubnet(var.cidr, 4, i)]
  private_subnets = [for i in range(length(var.azs)) : cidrsubnet(var.cidr, 4, i + length(var.azs))]

  enable_nat_gateway = true

  enable_dns_support   = true
  enable_dns_hostnames = true
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_security_group" "alb" {
  name        = "service-alb"
  description = "Allow HTTP from peered VPC"
  vpc_id      = module.service_vpc.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.client_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "web" {
  name        = "service-web"
  description = "Allow ALB to reach web"
  vpc_id      = module.service_vpc.vpc_id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "web" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.micro"
  subnet_id              = module.service_vpc.private_subnets[0]
  vpc_security_group_ids = [aws_security_group.web.id]

  user_data = <<-EOF
              #!/bin/bash
              dnf install -y nginx
              echo "<h1>Service VPC via VPC Peering</h1>" > /usr/share/nginx/html/index.html
              systemctl enable --now nginx
              EOF

  metadata_options {
    http_tokens = "required"
  }

  iam_instance_profile = aws_iam_instance_profile.web.name
}

resource "aws_lb" "internal" {
  name               = "service-internal-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = module.service_vpc.private_subnets
}

resource "aws_lb_target_group" "web" {
  name     = "service-web"
  port     = 80
  protocol = "HTTP"
  vpc_id   = module.service_vpc.vpc_id
  health_check {
    path                = "/"
    matcher             = "200"
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_target_group_attachment" "web" {
  target_group_arn = aws_lb_target_group.web.arn
  target_id        = aws_instance.web.id
  port             = 80
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

resource "aws_iam_role" "web" {
  name               = "service-web"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.web.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "web" {
  name = "service-web"
  role = aws_iam_role.web.name
}

output "alb_dns" {
  value = aws_lb.internal.dns_name
}


resource "aws_vpc_peering_connection" "client" {
  peer_vpc_id = var.client_vpc_id
  vpc_id      = module.service_vpc.vpc_id
  auto_accept = true

  tags = {
    Name = "service-to-client"
  }
}

output "peering_id" {
  value = aws_vpc_peering_connection.client.id
}


resource "aws_route" "to_client" {
  for_each = toset(module.service_vpc.private_route_table_ids)

  route_table_id            = each.value
  destination_cidr_block    = var.client_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.client.id
}
