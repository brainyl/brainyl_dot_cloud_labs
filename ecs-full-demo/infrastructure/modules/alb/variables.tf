variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC"
  type        = string
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs"
  type        = list(string)
}

variable "alb_security_group_id" {
  description = "ID of ALB security group"
  type        = string
}

variable "certificate_arn" {
  description = "ARN of ACM certificate for HTTPS (optional)"
  type        = string
  default     = ""
}

variable "deregistration_delay" {
  description = "Time in seconds for ALB to wait before deregistering a target"
  type        = number
  default     = 30
}

variable "health_check_interval" {
  description = "Interval in seconds between health checks"
  type        = number
  default     = 15
}

variable "health_check_timeout" {
  description = "Timeout in seconds for health check"
  type        = number
  default     = 5
}

variable "healthy_threshold" {
  description = "Number of consecutive successful health checks"
  type        = number
  default     = 2
}

variable "unhealthy_threshold" {
  description = "Number of consecutive failed health checks"
  type        = number
  default     = 2
}
