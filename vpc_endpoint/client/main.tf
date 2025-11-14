// client/main.tf
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
  private_subnets = [for i, az in enumerate(var.azs) : cidrsubnet(var.cidr, 4, i)]

  enable_dns_hostnames = true
  enable_dns_support   = true
}

resource "aws_security_group" "endpoint" {
  name        = "client-endpoint"
  description = "Allow HTTP/HTTPS egress"
  vpc_id      = module.client_vpc.vpc_id

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

