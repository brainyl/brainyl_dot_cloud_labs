
Amazon’s Terraform provider finally gained first-party support for Bedrock AgentCore in v6.17.0. That means you can codify the full workflow—containerize your Strands agent, publish it to ECR, and register an AgentCore runtime endpoint—without resorting to consoles or hand-rolled SDK scripts. This walkthrough packages the starter app and infrastructure below so you can recreate them in your own account.

## Prerequisites

Before touching Terraform, line up the following tools and account access:

- **AWS account** in the target region (this guide uses `us-west-2`).
- **IAM user or role** with permissions to push images to ECR, manage AgentCore runtimes, create IAM roles, and write CloudWatch Logs/X-Ray telemetry. Configure the credentials locally via `aws configure` or environment variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`).
- **Docker 24+** with `buildx` for multi-architecture builds (`linux/arm64`).
- **Terraform 1.9+** with the AWS provider pinned to `>= 6.17.0`.
- **Python 3.11** (optional) if you want to run the agent locally with `uv` before packaging.

Export a few environment variables that both Docker and Terraform will reuse:

```bash
export AWS_REGION=us-west-2
export AWS_DEFAULT_REGION=$AWS_REGION
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ECR_REPO_URI="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/agent"
```

## 1. Scaffold the agent application

Drop the following three files into a working directory. They install `strands-agents`, `bedrock-agentcore`, and `boto3`, then initialize a `BedrockAgentCoreApp` configured to use Claude 3.7 Sonnet. The handler logs the event, instantiates a Strands `Agent`, and returns the model response.

```text
requirements.txt
index.py
Dockerfile
```

```txt
# requirements.txt
strands-agents
bedrock-agentcore
boto3
```

```python
# index.py
"""
Simple agent that can be used to test BedrockAgentCoreApp.
"""

import argparse
import json
import logging
import os

os.environ["OTEL_TRACES_EXPORTER"] = "console"

from strands import Agent
from strands.models import BedrockModel
from bedrock_agentcore.runtime import BedrockAgentCoreApp

logger = logging.getLogger()
logger.setLevel(logging.INFO)

app = BedrockAgentCoreApp()

nova_pro = BedrockModel(
    model_id="us.amazon.nova-pro-v1:0",
)

if not logger.handlers:
    console_handler = logging.StreamHandler()
    console_handler.setLevel(logging.INFO)
    formatter = logging.Formatter(
        "%(asctime)s - %(name)s - %(levelname)s - %(message)s"
    )
    console_handler.setFormatter(formatter)
    logger.addHandler(console_handler)


SYSTEM_PROMPT = """
You are a helpful assistant that answers infrastructure and DevOps questions clearly and concisely.
"""


@app.entrypoint
def invoke(payload):
    """Simple agent that can be used to test BedrockAgentCoreApp."""
    logger.info("Received payload: %s", json.dumps(payload, default=str))

    try:
        agent = Agent(
            system_prompt=SYSTEM_PROMPT,
            model=nova_pro,
        )
        user_message = payload.get("prompt", "Hello")
        response = agent(user_message)
        return str(response)
    except Exception as exc:
        logger.error("Failed to initialize or use agent: %s", exc)
        return str(exc)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Run Bedrock AgentCore app")
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("PORT", 8080)),
        help="Port to bind the server (default: 8080 or PORT env var)",
    )
    args = parser.parse_args()
    
    logger.info("Starting server on port %d", args.port)
    app.run(port=args.port)

```

```dockerfile
# Dockerfile
FROM --platform=linux/arm64 ghcr.io/astral-sh/uv:python3.11-bookworm-slim
WORKDIR /app

ENV UV_SYSTEM_PYTHON=1 UV_COMPILE_BYTECODE=1

COPY requirements.txt requirements.txt
RUN uv pip install -r requirements.txt

ENV AWS_REGION=us-west-2
ENV AWS_DEFAULT_REGION=us-west-2

ENV DOCKER_CONTAINER=1

RUN useradd -m -u 1000 bedrock_agentcore
USER bedrock_agentcore

EXPOSE 8080
EXPOSE 8000

COPY index.py .

CMD ["python", "-m", "index"]
```

Double-check that `SYSTEM_PROMPT` contains the instructions you want the agent to follow. For local smoke tests, first install `uv` (if not already installed). On Linux:

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

Then create a virtual environment and install dependencies:

```bash
uv venv
source .venv/bin/activate
uv pip install -r requirements.txt
```

Start the server on a specific port:

```bash
python index.py --port 9090
```

In another terminal, invoke the agent with a curl request:

```bash
curl -X POST http://localhost:9090/invocations \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Give me a quick Terraform tip"}'
```

You should receive a response like:

```
"Use `terraform import` to manage existing resources: Import existing infrastructure into your Terraform state to manage it with Terraform going forward.\n"
```

Check the server logs for structured output showing the received payload and agent processing.

## 2. Build and push the container image

Ensure the environment variables from the Prerequisites section are set:

```bash
export AWS_REGION=us-west-2
export AWS_DEFAULT_REGION=$AWS_REGION
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ECR_REPO_URI="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/agent"
```

Create the Dockerfile exactly as provided to ensure the runtime matches the Bedrock AgentCore expectations (Python 3.11 on `linux/arm64`, non-root user, port exposure). Then authenticate to ECR, build, tag, and push the image:

```bash
aws ecr create-repository --repository-name agent --image-tag-mutability MUTABLE --region $AWS_REGION || true

TAG=$(date +%Y%m%d-%H%M%S)
IMAGE_URI="$ECR_REPO_URI:$TAG"
LATEST_URI="$ECR_REPO_URI:dev-latest"  # adjust ENV label if desired

aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_REPO_URI"

docker buildx build --platform linux/arm64 \
  -t "$IMAGE_URI" \
  -t "$LATEST_URI" \
  --push \
  -f Dockerfile .
```

The push emits two tags: an immutable timestamp and an environment alias. Capture `IMAGE_URI`; Terraform will feed it into the runtime resource.

## 3. Configure Terraform

Initialize a Terraform workspace with a minimal `versions.tf` and `main.tf` (or split into modules if you prefer). Pin the provider and declare variables for reusable inputs.

```terraform
// versions.tf
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.17.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "us-west-2"
}

variable "image_uri" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

data "aws_caller_identity" "current" {}
```

Feed your freshly pushed container URI into `var.image_uri` via a `terraform.tfvars` file or `-var` CLI flag.

## 4. Provision the AgentCore IAM runtime role

AgentCore assumes a service role that needs ECR, logging, telemetry, Bedrock model invocation, memory APIs, and optional downstream services (Secrets Manager, Lambda). The inline policy below covers those surfaces and intentionally grants broad access so the tutorial works out of the box. As soon as the runtime is responding, tighten each statement to match your production guardrails and remove permissions your agent does not require. Drop it into Terraform using `aws_iam_role` and `aws_iam_role_policy` resources:

```terraform
resource "aws_iam_role" "agentcore_runtime_role" {
  name = "agentcore-runtime-role"
  path = "/service-role/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "bedrock-agentcore.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "agentcore_runtime_policy" {
  name = "agentcore-runtime-policy"
  role = aws_iam_role.agentcore_runtime_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
        Resource = [
          "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/*"
        ]
      },
      {
        Effect = "Allow"
        Action = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["logs:DescribeLogStreams", "logs:CreateLogGroup"]
        Resource = [
          "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*"
        ]
      },
      {
        Effect = "Allow"
        Action = ["logs:DescribeLogGroups"]
        Resource = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:*"]
      },
      {
        Effect = "Allow"
        Action = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = [
          "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*:log-stream:*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "xray:GetSamplingRules",
          "xray:GetSamplingTargets"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = "bedrock-agentcore"
          }
        }
      },
      {
        Effect = "Allow"
        Action = ["bedrock-agentcore:InvokeAgentRuntime"]
        Resource = [
          "arn:aws:bedrock-agentcore:${var.region}:${data.aws_caller_identity.current.account_id}:runtime/*"
        ]
      },
      {
        Effect = "Allow"
        Action = ["bedrock-agentcore:CreateMemory"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock-agentcore:CreateEvent",
          "bedrock-agentcore:GetEvent",
          "bedrock-agentcore:GetMemory",
          "bedrock-agentcore:GetMemoryRecord",
          "bedrock-agentcore:ListActors",
          "bedrock-agentcore:ListEvents",
          "bedrock-agentcore:ListMemoryRecords",
          "bedrock-agentcore:ListSessions",
          "bedrock-agentcore:DeleteEvent",
          "bedrock-agentcore:DeleteMemoryRecord",
          "bedrock-agentcore:RetrieveMemoryRecords"
        ]
        Resource = [
          "arn:aws:bedrock-agentcore:${var.region}:${data.aws_caller_identity.current.account_id}:memory/*"
        ]
      },
      {
        Effect = "Allow"
        Action = ["bedrock-agentcore:GetResourceApiKey"]
        Resource = [
          "arn:aws:bedrock-agentcore:${var.region}:${data.aws_caller_identity.current.account_id}:token-vault/default",
          "arn:aws:bedrock-agentcore:${var.region}:${data.aws_caller_identity.current.account_id}:token-vault/default/apikeycredentialprovider/*",
          "arn:aws:bedrock-agentcore:${var.region}:${data.aws_caller_identity.current.account_id}:workload-identity-directory/default",
          "arn:aws:bedrock-agentcore:${var.region}:${data.aws_caller_identity.current.account_id}:workload-identity-directory/default/workload-identity/index-*"
        ]
      },
      {
        Effect = "Allow"
        Action = ["bedrock-agentcore:GetResourceOauth2Token"]
        Resource = [
          "arn:aws:bedrock-agentcore:${var.region}:${data.aws_caller_identity.current.account_id}:token-vault/default",
          "arn:aws:bedrock-agentcore:${var.region}:${data.aws_caller_identity.current.account_id}:token-vault/default/oauth2credentialprovider/*",
          "arn:aws:bedrock-agentcore:${var.region}:${data.aws_caller_identity.current.account_id}:workload-identity-directory/default",
          "arn:aws:bedrock-agentcore:${var.region}:${data.aws_caller_identity.current.account_id}:workload-identity-directory/default/workload-identity/index-*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock-agentcore:GetWorkloadAccessToken",
          "bedrock-agentcore:GetWorkloadAccessTokenForJWT",
          "bedrock-agentcore:GetWorkloadAccessTokenForUserId"
        ]
        Resource = [
          "arn:aws:bedrock-agentcore:${var.region}:${data.aws_caller_identity.current.account_id}:workload-identity-directory/default",
          "arn:aws:bedrock-agentcore:${var.region}:${data.aws_caller_identity.current.account_id}:workload-identity-directory/default/workload-identity/index-*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock:ApplyGuardrail"
        ]
        Resource = [
          "arn:aws:bedrock:*::foundation-model/*",
          "arn:aws:bedrock:${var.region}:${data.aws_caller_identity.current.account_id}:*"
        ]
      },
      {
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue", "ssm:GetParameter"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["lambda:InvokeFunction"]
        Resource = "*"
      }
    ]
  })
}
```

Output the role ARN for reuse:

```terraform
output "agentcore_runtime_role_arn" {
  value = aws_iam_role.agentcore_runtime_role.arn
}
```

## 5. Create the AgentCore runtime and endpoint

With the IAM role and container image in place, configure the two new Terraform resources:

```terraform
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
```

If you prefer a private runtime, swap `network_mode` to `VPC` and include subnet and security group IDs.

## 6. Apply and validate

Initialize and apply the stack:

```bash
terraform init
terraform apply \
  -var "region=$AWS_REGION" \
  -var "image_uri=$IMAGE_URI" \
  -var "tags={Environment=dev,Project=agentcore-demo}"
```

After the apply completes, the outputs include the runtime ID and endpoint ARN. Invoke the runtime with a sample payload using the Bedrock AgentCore Python SDK. Create `test_runtime.py`:

```python
import boto3
import json
import os
import uuid

# Initialize the AgentCore Runtime client
agent_core_client = boto3.client('bedrock-agentcore')

# Get the runtime ARN from environment variable (set from Terraform output)
agent_arn = os.environ.get('RUNTIME_ARN')
session_id = str(uuid.uuid4())

# Prepare the payload - use errors='replace' to handle invalid UTF-8 bytes
prompt = "Give me a quick Terraform tip"
payload = json.dumps({"prompt": prompt}).encode('utf-8', errors='replace')

# Invoke the agent
response = agent_core_client.invoke_agent_runtime(
    agentRuntimeArn=agent_arn,
    runtimeSessionId=session_id,
    payload=payload
)

# Read and display the response
# The response field contains a StreamingBody that needs to be read
response_body = response['response'].read().decode('utf-8')
print("Response body:", response_body)
result = json.loads(response_body)
print(json.dumps(result, indent=2))
```

Run it with the runtime ARN from Terraform:

```bash
export RUNTIME_ARN=$(terraform output -raw agent_runtime_arn)
python3 test_runtime.py
```

You should see output like:

```bash
Response body: "Use `terraform console` to interactively evaluate expressions and interpolate values from your Terraform configuration. This is useful for debugging and understanding the state of your infrastructure code without applying changes.\n"
"Use `terraform console` to interactively evaluate expressions and interpolate values from your Terraform configuration. This is useful for debugging and understanding the state of your infrastructure code without applying changes.\n"
```

Check CloudWatch Logs (`/aws/bedrock-agentcore/runtimes/agent_runtime*`) for the structured log output you added in `index.py`. You should see the event JSON and the agent's response.

## 7. Cleanup

When you're done testing, destroy the Terraform resources to avoid ongoing costs:

```bash
terraform destroy \
  -var "region=$AWS_REGION" \
  -var "image_uri=$IMAGE_URI" \
  -var "tags={Environment=dev,Project=agentcore-demo}"
```

Since the ECR repository was created manually, delete it separately:

```bash
aws ecr delete-repository \
  --repository-name agent \
  --force \
  --region $AWS_REGION
```

## 8. Production considerations

The tutorial policy above grants broad permissions to get you running quickly. Before deploying to production, tighten IAM scopes, add observability, and establish a repeatable image update workflow.

**Rotate container images safely.** When you modify the agent code, rebuild and push a new tag to ECR. Update `var.image_uri` in Terraform (or store it in SSM Parameter Store) and run `terraform apply` to roll the runtime. Terraform will update the runtime with the new image URI without recreating the endpoint. 

**Add observability beyond console logs.** The Dockerfile sets `OTEL_TRACES_EXPORTER=console` for local debugging. In production, configure OpenTelemetry to ship traces and metrics to your observability backend.

**Scope IAM permissions.** The tutorial policy intentionally grants broad access. Narrow it down: restrict ECR repository ARNs to specific repositories, limit Bedrock model invocations to the exact models your agent uses (e.g., `us.amazon.nova-pro-v1:0`), and remove Secrets Manager or Lambda permissions if your runtime doesn't call them. If you encrypt CloudWatch Logs or store secrets in KMS, add `kms:Decrypt` and `kms:DescribeKey` permissions scoped to your key ARNs.

**Promote across environments.** Mirror this stack in staging and production by parameterizing the Terraform variables. Use different ECR repository prefixes (`agent-staging`, `agent-prod`), environment-specific tags, and separate IAM roles per environment. Store the `image_uri` variable in environment-specific `terraform.tfvars` files or SSM Parameter Store, and use CI/CD pipelines to build, push, and apply Terraform changes automatically.

## Conclusion

You now have a complete, codified workflow for deploying Bedrock AgentCore runtimes: scaffold the agent application, build and push the container to ECR, provision the runtime and endpoint with Terraform, and invoke it via the Python SDK. The infrastructure lives in code, so you can version control changes, review them in pull requests, and roll back with confidence. When you need to update the agent, rebuild the image, push a new tag, and let Terraform handle the rollout.

**Key takeaways:**

- Terraform provider v6.17.0+ supports Bedrock AgentCore resources natively—no custom providers or workarounds needed.
- Containerize your bedrock agent with the correct platform (`linux/arm64`), non-root user, and port exposure for AgentCore compatibility.
- Use direct resource references in Terraform (e.g., `aws_iam_role.agentcore_runtime_role.arn`) instead of variables when resources are in the same stack.
- Invoke runtimes programmatically with boto3 using the `invoke_agent_runtime` API and a unique session ID per conversation.
- Always scope IAM policies to production requirements—the tutorial policy is intentionally permissive for learning.

Next steps: integrate this into your CI/CD pipeline, add monitoring dashboards for runtime health, and explore Bedrock AgentCore's memory and event APIs for stateful agent conversations.
