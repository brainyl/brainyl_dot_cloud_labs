terraform {
  required_version = ">= 1.13.4"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.20.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
  }

  backend "s3" {
    bucket         = "arn:aws:s3:::tfstate-ecs-bluegreen-386452075078"
    key            = "ecs-fargate-blue-green-deployments-oidc/terraform.tfstate"
    region         = "us-west-2"
    dynamodb_table = "tflock-ecs-bluegreen"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}