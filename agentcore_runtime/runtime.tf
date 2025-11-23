resource "aws_bedrockagentcore_agent_runtime" "this" {
  agent_runtime_name = "agent_runtime"
  role_arn           = aws_iam_role.agentcore_runtime_role.arn

  agent_runtime_artifact {
    container_configuration {
      container_uri = var.image_uri
    }
  }

  network_configuration {
    network_mode = "PUBLIC"
  }

  tags = var.tags
}

resource "aws_bedrockagentcore_agent_runtime_endpoint" "this" {
  name             = "agent_runtime_endpoint"
  agent_runtime_id = aws_bedrockagentcore_agent_runtime.this.agent_runtime_id

  depends_on = [aws_bedrockagentcore_agent_runtime.this]
}

output "agent_runtime_id" {
  value = aws_bedrockagentcore_agent_runtime.this.agent_runtime_id
}

output "agent_runtime_arn" {
  value = aws_bedrockagentcore_agent_runtime_endpoint.this.agent_runtime_arn
}