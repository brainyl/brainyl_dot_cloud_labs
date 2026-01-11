// service/variables.tf
variable "region" {
  type    = string
  default = "us-west-2"
}

variable "cidr" {
  type    = string
  default = "10.10.0.0/16"
}

variable "client_cidr" {
  description = "CIDR block of the client VPC allowed into the ALB"
  type        = string
  default     = "10.20.0.0/16"
}

variable "client_vpc_id" {
  description = "VPC ID of the client stack for peering auto-accept"
  type        = string
  default     = "vpc-097c4d9b8ce1efa4f"
}

variable "azs" {
  type    = list(string)
  default = ["us-west-2a", "us-west-2b"]
}
