data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

data "aws_eks_cluster_auth" "this" {
  name = var.cluster_name
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "ratify_signer_permissions" {
  statement {
    sid     = "SignerRevocation"
    actions = ["signer:GetRevocationStatus"]
    effect  = "Allow"
    resources = [
      aws_signer_signing_profile.eks_secure.arn,
      "arn:aws:signer:${var.region}:${data.aws_caller_identity.current.account_id}:signing-jobs/*"
    ]
  }
}

resource "aws_iam_role" "ratify" {
  name = "${var.cluster_name}-ratify"

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

resource "aws_iam_role_policy_attachment" "ratify_ecr" {
  role       = aws_iam_role.ratify.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy" "ratify_signer" {
  role   = aws_iam_role.ratify.id
  policy = data.aws_iam_policy_document.ratify_signer_permissions.json
}

resource "aws_eks_pod_identity_association" "ratify" {
  cluster_name    = var.cluster_name
  namespace       = "gatekeeper-system"
  service_account = "ratify-admin"
  role_arn        = aws_iam_role.ratify.arn
}

resource "kubernetes_service_account" "ratify" {
  metadata {
    name      = "ratify-admin"
    namespace = "gatekeeper-system"
  }
}
