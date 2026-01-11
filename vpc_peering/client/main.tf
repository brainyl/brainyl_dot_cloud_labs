// client/main.tf
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

module "client_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.5.0"

  name = "client"
  cidr = var.cidr

  azs             = var.azs
  private_subnets = [for i in range(length(var.azs)) : cidrsubnet(var.cidr, 4, i)]

  enable_nat_gateway = false
  enable_dns_support = true
}

resource "aws_security_group" "endpoints" {
  name        = "client-endpoints"
  description = "Allow interface endpoints from inside the VPC"
  vpc_id      = module.client_vpc.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = module.client_vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.client_vpc.private_subnets
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = module.client_vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.client_vpc.private_subnets
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = module.client_vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.client_vpc.private_subnets
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
}


data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_security_group" "client" {
  name        = "client-tester"
  description = "Allow outbound for testing and SSM"
  vpc_id      = module.client_vpc.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "tester" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.micro"
  subnet_id              = module.client_vpc.private_subnets[0]
  vpc_security_group_ids = [aws_security_group.client.id]

  user_data = <<-EOF
              #!/bin/bash
              dnf install -y curl
              EOF

  metadata_options {
    http_tokens = "required"
  }

  iam_instance_profile = aws_iam_instance_profile.tester.name
}

resource "aws_iam_role" "tester" {
  name               = "client-tester"
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
  role       = aws_iam_role.tester.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "tester" {
  name = "client-tester"
  role = aws_iam_role.tester.name
}

output "vpc_id" {
  value = module.client_vpc.vpc_id
}

output "subnet_ids" {
  value = module.client_vpc.private_subnets
}

output "tester_instance_id" {
  value = aws_instance.tester.id
}


resource "aws_route" "to_service" {
  for_each = toset(module.client_vpc.private_route_table_ids)

  route_table_id            = each.value
  destination_cidr_block    = var.service_cidr
  vpc_peering_connection_id = var.peering_id
}