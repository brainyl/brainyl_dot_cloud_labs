resource "aws_ecr_repository" "webhook" {
  name                 = "${local.name_prefix}-webhook-receiver"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(local.tags, {
    Name = "${local.name_prefix}-webhook-receiver"
  })
}

output "webhook_ecr_repository_url" {
  description = "ECR repository URL for webhook receiver"
  value       = aws_ecr_repository.webhook.repository_url
}