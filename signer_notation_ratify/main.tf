terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.29"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.11"
    }
  }
}

provider "aws" {
  region = var.region
}

resource "aws_ecr_repository" "secure_demo" {
  name                 = var.repository_name
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  encryption_configuration {
    encryption_type = "KMS"
  }
}

resource "aws_signer_signing_profile" "eks_secure" {
  name        = var.signing_profile_name
  platform_id = "Notation-OCI-SHA384-ECDSA"

  signature_validity_period {
    value = 135
    type  = "DAYS"
  }
}

output "repository_url" {
  value = aws_ecr_repository.secure_demo.repository_url
}

output "signing_profile_arn" {
  value = aws_signer_signing_profile.eks_secure.arn
}
