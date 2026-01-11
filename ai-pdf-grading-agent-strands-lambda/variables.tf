variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "us-west-2"
}

variable "function_name" {
  description = "Lambda function name"
  type        = string
  default     = "pdf-grading-agent"
}