variable "create" {
  description = "Controls whether NAT instances should be created"
  type        = bool
  default     = false
}

variable "name" {
  description = "Name prefix applied to NAT instance resources"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the NAT instances will be deployed"
  type        = string
  default     = null
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs where NAT instances can be launched"
  type        = list(string)
  default     = []
}

variable "azs" {
  description = "List of availability zones aligned with the provided public subnets"
  type        = list(string)
  default     = []
}

variable "nat_count" {
  description = "Number of NAT instances to create"
  type        = number
  default     = 0
}

variable "single_nat_gateway" {
  description = "Whether a single NAT instance should be shared across AZs"
  type        = bool
  default     = false
}

variable "instance_type" {
  description = "Instance type used for the NAT instances"
  type        = string
  default     = "t4g.nano"
}

variable "ami_id" {
  description = "AMI ID used for the NAT instances (must support IP forwarding)"
  type        = string
  default     = "ami-0aac6113247ca0b3f"
}

variable "allowed_inbound_cidrs" {
  description = "CIDR blocks allowed to send traffic to the NAT instances"
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to all NAT instance resources"
  type        = map(string)
  default     = {}
}