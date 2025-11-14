locals {
  name = var.cluster_name

  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Project     = local.name
    Environment = "lab"
    ManagedBy   = "terraform"
  }
}
