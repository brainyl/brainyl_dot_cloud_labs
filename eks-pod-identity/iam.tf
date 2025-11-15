locals {
  account_id = data.aws_caller_identity.current.account_id
  policy_name = "pod-identity-demo-cloudwatch"
}

resource "aws_iam_role" "pod_identity" {
  name = "${var.cluster_name}-pod-identity"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })
}

resource "aws_iam_policy" "pod_identity" {
  name        = local.policy_name
  description = "Allow writing logs to CloudWatch for demo purposes."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.region}:${local.account_id}:*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "pod_identity" {
  role       = aws_iam_role.pod_identity.name
  policy_arn = aws_iam_policy.pod_identity.arn
}


resource "aws_eks_pod_identity_association" "demo" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = "cw-writer"
  role_arn        = aws_iam_role.pod_identity.arn
}

resource "kubernetes_namespace" "demo" {
  metadata {
    name = var.namespace
  }
}

resource "kubernetes_service_account" "demo" {
  metadata {
    name      = aws_eks_pod_identity_association.demo.service_account
    namespace = var.namespace
    labels = {
      "app" = "cw-writer"
    }
  }
}
