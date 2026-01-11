variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "us-west-2"
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "ghost-blog"
}

variable "domain_name" {
  description = "Domain name for Ghost blog (e.g. blog.example.com)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of availability zones"
  type        = list(string)
  default     = ["us-west-2a", "us-west-2b"]
}

variable "ec2_instance_type" {
  description = "EC2 instance type for Ghost servers"
  type        = string
  default     = "t3.small"
}

variable "asg_desired_capacity" {
  description = "Desired number of EC2 instances"
  type        = number
  default     = 2
}

variable "asg_min_size" {
  description = "Minimum number of EC2 instances"
  type        = number
  default     = 2
}

variable "asg_max_size" {
  description = "Maximum number of EC2 instances"
  type        = number
  default     = 4
}

variable "db_master_username" {
  description = "Master username for Aurora"
  type        = string
  default     = "ghostadmin"
}

variable "db_master_password" {
  description = "Master password for Aurora (not used - RDS managed password is used instead)"
  type        = string
  sensitive   = true
  default     = null
}

variable "db_name" {
  description = "Database name for Ghost"
  type        = string
  default     = "ghost_production"
}

variable "acm_certificate_arn" {
  description = "ARN of an existing validated ACM certificate in us-east-1. If not provided, a new certificate will be created (must be validated before CloudFront can use it)"
  type        = string
  default     = null
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID. If not provided, Terraform will try to find it automatically based on domain_name"
  type        = string
  default     = null
}

