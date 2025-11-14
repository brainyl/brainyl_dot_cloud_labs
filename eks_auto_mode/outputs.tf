output "cluster_name" {
  description = "Deployed EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "aws_region" {
  description = "Region where the cluster is deployed"
  value       = var.aws_region
}
