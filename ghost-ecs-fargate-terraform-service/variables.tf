variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "project_name" {
  description = "Project name prefix"
  type        = string
  default     = "ghost-ecs"
}

variable "ghost_url" {
  description = "Public URL for Ghost (defaults to ALB DNS if not provided)"
  type        = string
  default     = ""
}

variable "admin_cidr" {
  description = "CIDR block allowed to access the ALB"
  type        = string
  default     = "0.0.0.0/0"
}

variable "db_name" {
  description = "Ghost database name"
  type        = string
  default     = "ghost_production"
}

variable "db_username" {
  description = "Ghost database username"
  type        = string
  default     = "ghostadmin"
}

variable "ecs_desired_count" {
  description = "Desired number of Ghost tasks"
  type        = number
  default     = 1
}

variable "ghost_cpu" {
  description = "Fargate CPU units for Ghost"
  type        = number
  default     = 512
}

variable "ghost_memory" {
  description = "Fargate memory (MiB) for Ghost"
  type        = number
  default     = 1024
}

variable "webhook_cpu" {
  description = "Fargate CPU units for webhook receiver"
  type        = number
  default     = 256
}

variable "webhook_memory" {
  description = "Fargate memory (MiB) for webhook receiver"
  type        = number
  default     = 512
}
