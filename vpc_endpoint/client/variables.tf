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
  default = ["us-west-2a", "us-west-2b", "us-west-2c"]
}

variable "endpoint_service_name" {
  type        = string
  description = "Service name from the service stack (e.g., com.amazonaws.vpce.us-west-2.vpce-svc-1234567890abcdef)"
}
