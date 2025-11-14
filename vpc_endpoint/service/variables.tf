// service/variables.tf
variable "region" {
  type    = string
  default = "us-west-2"
}

variable "cidr" {
  type    = string
  default = "10.10.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["us-west-2a", "us-west-2b", "us-west-2c"]
}

variable "allowed_client_cidr" {
  type        = string
  description = "CIDR block for the client VPC that should be allowed through the NLB security group"
  default     = "10.20.0.0/16"
}