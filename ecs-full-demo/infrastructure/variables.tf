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

# Networking
variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "enable_nat_gateway" {
  description = "Enable NAT Gateway for private subnets"
  type        = bool
  default     = true
}

# ALB Configuration
variable "certificate_arn" {
  description = "ARN of ACM certificate for HTTPS (optional)"
  type        = string
  default     = ""
}

variable "alb_deregistration_delay" {
  description = "Time in seconds for ALB to wait before deregistering a target"
  type        = number
  default     = 30
}

variable "alb_health_check_interval" {
  description = "Interval in seconds between health checks"
  type        = number
  default     = 15
}

variable "alb_health_check_timeout" {
  description = "Timeout in seconds for health check"
  type        = number
  default     = 5
}

variable "alb_healthy_threshold" {
  description = "Number of consecutive successful health checks"
  type        = number
  default     = 2
}

variable "alb_unhealthy_threshold" {
  description = "Number of consecutive failed health checks"
  type        = number
  default     = 2
}

# MySQL Configuration
variable "mysql_cpu" {
  description = "CPU units for MySQL container (1024 = 1 vCPU)"
  type        = number
  default     = 512
}

variable "mysql_memory" {
  description = "Memory in MB for MySQL container"
  type        = number
  default     = 1024
}

# Backend Configuration
variable "backend_cpu" {
  description = "CPU units for Backend container (1024 = 1 vCPU)"
  type        = number
  default     = 256
}

variable "backend_memory" {
  description = "Memory in MB for Backend container"
  type        = number
  default     = 1024
}

# Frontend Configuration
variable "frontend_cpu" {
  description = "CPU units for Frontend container (1024 = 1 vCPU)"
  type        = number
  default     = 256
}

variable "frontend_memory" {
  description = "Memory in MB for Frontend container"
  type        = number
  default     = 512
}
