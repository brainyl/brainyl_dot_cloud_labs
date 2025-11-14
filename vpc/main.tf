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