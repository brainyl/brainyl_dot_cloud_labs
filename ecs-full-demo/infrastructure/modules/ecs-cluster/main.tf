# ECS Cluster using community module
module "ecs_cluster" {
  source  = "terraform-aws-modules/ecs/aws//modules/cluster"
  version = "~> 5.0"

  cluster_name = "${var.name_prefix}-cluster"

  # Service Connect defaults - requires Cloud Map namespace ARN
  # We'll create the namespace separately
  cluster_service_connect_defaults = {
    namespace = aws_service_discovery_http_namespace.this.arn
  }

  # CloudWatch Container Insights
  cluster_configuration = {
    execute_command_configuration = {
      logging = "OVERRIDE"
      log_configuration = {
        cloud_watch_log_group_name = aws_cloudwatch_log_group.ecs_exec.name
      }
    }
  }

  # Fargate capacity providers - managed externally in main.tf
  fargate_capacity_providers = {}

  tags = {
    Name = "${var.name_prefix}-cluster"
  }
}

# Cloud Map HTTP namespace for Service Connect
resource "aws_service_discovery_http_namespace" "this" {
  name        = "${var.name_prefix}.local"
  description = "Service Connect namespace for ${var.name_prefix}"

  tags = {
    Name = "${var.name_prefix}-service-connect"
  }
}

# CloudWatch Log Group for ECS Exec
resource "aws_cloudwatch_log_group" "ecs_exec" {
  name              = "/aws/ecs/${var.name_prefix}/exec"
  retention_in_days = 7

  tags = {
    Name = "${var.name_prefix}-ecs-exec-logs"
  }
}
