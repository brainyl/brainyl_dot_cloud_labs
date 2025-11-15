terraform {
  required_version = ">= 1.13.4"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.20.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.27.0"
    }
  }
}

provider "aws" {
  region = var.region
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}
