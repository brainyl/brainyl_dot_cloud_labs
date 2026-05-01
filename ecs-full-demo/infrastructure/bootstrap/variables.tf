variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "simple-app"
}

variable "environment" {
  description = "Environment name (dev, staging, production)"
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "ecr_repositories" {
  description = "List of ECR repository names to create"
  type        = list(string)
  default     = ["mysql", "backend", "frontend"]
}
