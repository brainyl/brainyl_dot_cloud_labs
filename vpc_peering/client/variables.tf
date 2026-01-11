// client/variables.tf
variable "region" {
  type    = string
  default = "us-west-2"
}

variable "cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["us-west-2a", "us-west-2b"]
}

variable "service_cidr" {
  description = "CIDR block of the service VPC allowed into the client VPC"
  type        = string
  default     = "10.10.0.0/16"
}

variable "peering_id" {
  description = "ID of the VPC peering connection created by the service stack"
  type        = string
  default     = "pcx-01be1d576711a0b79"
}

