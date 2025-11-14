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

module "client_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.5.0"

  name = "client"
  cidr = var.cidr

  azs             = var.azs
  private_subnets = [for i in range(length(var.azs)) : cidrsubnet(var.cidr, 4, i)]
  public_subnets  = [for i in range(length(var.azs)) : cidrsubnet(var.cidr, 4, i + length(var.azs))]

  enable_nat_gateway = true

  enable_dns_hostnames = true
  enable_dns_support   = true
}

resource "aws_security_group" "endpoint" {
  name        = "client-endpoint"
  description = "Allow HTTP/HTTPS egress"
  vpc_id      = module.client_vpc.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [module.client_vpc.vpc_cidr_block]
  }

  # Permit HTTPS so Session Manager can establish a control channel.
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Permit HTTP traffic to the PrivateLink-backed service.
  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_vpc_endpoint" "service" {
  vpc_id            = module.client_vpc.vpc_id
  service_name      = var.endpoint_service_name
  vpc_endpoint_type = "Interface"

  subnet_ids        = [module.client_vpc.private_subnets[0]]
  security_group_ids = [aws_security_group.endpoint.id]
  private_dns_enabled = false
}

output "endpoint_dns_name" {
  value = aws_vpc_endpoint.service.dns_entry[0].dns_name
}


resource "aws_iam_role" "ssm" {
  name               = "client-ssm"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_policy_attachment" "ssm_core" {
  name       = "client-ssm-core"
  roles      = [aws_iam_role.ssm.name]
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm" {
  name = "client-ssm"
  role = aws_iam_role.ssm.name
}

resource "aws_instance" "tester" {
  ami                  = data.aws_ami.al2023.id
  instance_type        = "t3.micro"
  subnet_id            = module.client_vpc.private_subnets[0]
  iam_instance_profile = aws_iam_instance_profile.ssm.name
  vpc_security_group_ids = [aws_security_group.endpoint.id]

  user_data = <<-EOF
              #!/bin/bash
              dnf install -y curl
              EOF
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
