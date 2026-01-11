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

module "blackbox_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.5.0"

  name = "blackbox"
  cidr = var.cidr

  azs             = var.azs
  private_subnets = [for i in range(length(var.azs)) : cidrsubnet(var.cidr, 4, i)]
  #public_subnets  = [for i in range(length(var.azs)) : cidrsubnet(var.cidr, 4, i + length(var.azs))]

  #enable_nat_gateway = true

  enable_dns_hostnames = true
  enable_dns_support   = true
}

# Security group for VPC interface endpoints
resource "aws_security_group" "vpc_interface_endpoint_sg" {
  name        = "blackbox-vpc-interface-endpoint-sg"
  description = "Security group for VPC interface endpoints"
  vpc_id      = module.blackbox_vpc.vpc_id

  # Allow HTTPS ingress from VPC (for service endpoints like SSM, S3, EC2 Messages, etc.)
  # Instances connect TO these endpoints
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [module.blackbox_vpc.vpc_cidr_block]
    description = "Allow HTTPS from VPC for service endpoints"
  }
  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name = "blackbox-vpc-interface-endpoint-sg"
    Type = "VPC Interface Endpoint"
  }
}

# Security group for EC2 instances
resource "aws_security_group" "ec2_sg" {
  name        = "blackbox-ec2-sg"
  description = "Security group for EC2 instances - allows port 80 from VPC and all outbound from VPC"
  vpc_id      = module.blackbox_vpc.vpc_id

  # Allow HTTP ingress from within the VPC
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [module.blackbox_vpc.vpc_cidr_block]
    description = "Allow HTTP from VPC"
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name = "blackbox-ec2-sg"
    Type = "EC2 Instance"
  }
}

# Allow SSH from interface endpoint security group to EC2 instances
resource "aws_security_group_rule" "ec2_ssh_from_interface_endpoint" {
  type                     = "ingress"
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.vpc_interface_endpoint_sg.id
  security_group_id        = aws_security_group.ec2_sg.id
  description              = "Allow SSH from interface endpoint security group"
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

resource "aws_iam_role" "ec2_role" {
  name               = "blackbox-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = {
    Name = "blackbox-ec2-role"
    Type = "EC2 Instance Role"
  }
}

resource "aws_iam_policy_attachment" "ssm_core" {
  name       = "blackbox-ec2-ssm-core"
  roles      = [aws_iam_role.ec2_role.name]
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_policy_attachment" "s3_read_only" {
  name       = "blackbox-ec2-s3-read-only"
  roles      = [aws_iam_role.ec2_role.name]
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

data "aws_iam_policy_document" "ecr_pull" {
  statement {
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "ecr_pull" {
  name        = "blackbox-ecr-pull-policy"
  description = "Allow EC2 instances to pull images from ECR"
  policy      = data.aws_iam_policy_document.ecr_pull.json

  tags = {
    Name = "blackbox-ecr-pull-policy"
  }
}

resource "aws_iam_role_policy_attachment" "ecr_pull" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.ecr_pull.arn
}

resource "aws_iam_instance_profile" "ec2" {
  name = "blackbox-ec2-profile"
  role = aws_iam_role.ec2_role.name

  tags = {
    Name = "blackbox-ec2-profile"
    Type = "EC2 Instance Profile"
  }
}