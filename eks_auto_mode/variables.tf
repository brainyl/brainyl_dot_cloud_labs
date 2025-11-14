variable "aws_region" {
  description = "AWS region for the EKS Auto Mode lab"
  type        = string
  default     = "us-west-2"
}

variable "cluster_name" {
  description = "Name for the EKS cluster and supporting resources"
  type        = string
  default     = "auto-mode-lab"
}

variable "eks_cluster_version" {
  description = "Kubernetes version for EKS"
  type        = string
  default     = "1.29"
}

variable "vpc_cidr" {
  description = "CIDR for the lab VPC"
  type        = string
  default     = "10.20.0.0/16"
}
