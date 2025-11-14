// service/main.tf
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
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
  private_subnets = [for i in range(length(var.azs)) : cidrsubnet(var.cidr, 4, i)]
  public_subnets  = [for i in range(length(var.azs)) : cidrsubnet(var.cidr, 4, i + length(var.azs))]

  enable_nat_gateway = true

  enable_dns_hostnames = true
  enable_dns_support   = true
}

// service/main.tf (continued)
resource "aws_network_interface" "web" {
  subnet_id       = module.service_vpc.private_subnets[0]
  security_groups = [aws_security_group.web.id]
}

resource "aws_instance" "web" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.micro"
  iam_instance_profile   = aws_iam_instance_profile.web.name
  network_interface {
    device_index         = 0
    network_interface_id = aws_network_interface.web.id
  }

  user_data = <<-EOF
              #!/bin/bash
              dnf install -y nginx
              echo "<h1>Welcome to the Service VPC</h1>" > /usr/share/nginx/html/index.html
              systemctl enable --now nginx
              EOF
}

resource "aws_security_group" "web" {
  name        = "service-web"
  description = "Allow NLB traffic"
  vpc_id      = module.service_vpc.vpc_id

  ingress {
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = [module.service_vpc.vpc_cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "web" {
  name               = "service-web"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_policy_attachment" "web_ssm" {
  name       = "service-web-ssm"
  roles      = [aws_iam_role.web.name]
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "web" {
  name = "service-web"
  role = aws_iam_role.web.name
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

module "nlb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "9.8.0"

  name = "service-nlb"

  load_balancer_type = "network"
  internal           = true
  vpc_id             = module.service_vpc.vpc_id
  subnets            = module.service_vpc.private_subnets

  enable_deletion_protection = false
  enable_cross_zone_load_balancing = false # see gotcha section

  # Security Group for NLB (used with PrivateLink)
  enforce_security_group_inbound_rules_on_private_link_traffic = "off"
  security_group_ingress_rules = {
    allow_client_vpc = {
      from_port   = 80
      to_port     = 80
      ip_protocol = "tcp"
      description = "Allow client VPC traffic"
      cidr_ipv4   = var.allowed_client_cidr
    }
  }
  security_group_egress_rules = {
    all = {
      ip_protocol = "-1"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }

  listeners = {
    http = {
      port     = 80
      protocol = "TCP"
      forward = {
        target_group_key = "web"
      }
    }
  }

  target_groups = {
    web = {
      name_prefix       = "svc"
      protocol          = "TCP"
      port              = 80
      target_type       = "ip"
      vpc_id            = module.service_vpc.vpc_id
      target_id         = aws_network_interface.web.private_ip
      preserve_client_ip = true
      health_check = {
        protocol = "TCP"
      }
    }
  }
}

resource "aws_vpc_endpoint_service" "web" {
  acceptance_required        = false
  network_load_balancer_arns = [module.nlb.arn]

  allowed_principals = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
}

data "aws_caller_identity" "current" {}


// service/outputs.tf
output "service_cidr" {
  value = module.service_vpc.vpc_cidr_block
}

output "endpoint_service_name" {
  value = aws_vpc_endpoint_service.web.service_name
}
