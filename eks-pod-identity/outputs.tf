output "namespace" {
  description = "Namespace that hosts the pod identity demo workload."
  value       = var.namespace
}

output "role_arn" {
  description = "IAM role assumed by pods via EKS Pod Identity."
  value       = aws_iam_role.pod_identity.arn
}
