variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "project_name" {
  description = "Project name prefix"
  type        = string
  default     = "nginx-ecs"
}

variable "nginx_url" {
  description = "Public URL for nginx (defaults to ALB DNS if not provided)"
  type        = string
  default     = ""
}

variable "admin_cidr" {
  description = "CIDR block allowed to access the ALB"
  type        = string
  default     = "0.0.0.0/0"
}

variable "ecs_desired_count" {
  description = "Desired number of nginx tasks"
  type        = number
  default     = 1
}

variable "ecs_cpu" {
  description = "Fargate CPU units"
  type        = number
  default     = 512
}

variable "ecs_memory" {
  description = "Fargate memory (MiB)"
  type        = number
  default     = 1024
}