variable "cluster_name" {
  type        = string
  description = "Name of the EKS cluster to bind the pod identity association to."
}

variable "region" {
  type        = string
  default     = "us-west-2"
  description = "AWS region where the cluster runs."
}

variable "namespace" {
  type        = string
  default     = "pod-identity-demo"
  description = "Namespace that will host the service account and workloads."
}
