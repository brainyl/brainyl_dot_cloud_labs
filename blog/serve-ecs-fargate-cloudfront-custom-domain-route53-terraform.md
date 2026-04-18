
An Application Load Balancer handles routing and health checks well. It distributes traffic across your ECS tasks, terminates connections, and gives you a stable DNS endpoint. But it doesn't cache anything. Every request, even for responses that rarely change, travels all the way back to the origin.

A CloudFront distribution sits in front of the ALB and adds what the ALB doesn't provide: edge caching, TLS with your own domain name, and a way to restrict the ALB so it only accepts traffic from CloudFront. That last part matters because a public ALB is reachable by anyone who knows the DNS name.

This post extends an ECS Fargate setup by adding CloudFront, locking down the ALB, provisioning a TLS certificate through ACM, and mapping a custom domain with Route 53. The base ECS infrastructure is deliberately simple — no blue/green, no dual listeners. If you want blue/green deployments, see the [ECS blue/green post](./ecs-blue-green-deployments-on-fargate.md). Everything here is Terraform, deployed through GitHub Actions with OIDC.

## What You'll Build

A CloudFront distribution that caches and serves traffic from an ECS Fargate app running behind an ALB. The ALB only accepts requests from CloudFront. A custom domain with TLS routes through Route 53.

```
Browser → lab.brainyl.cloud → Route 53 → CloudFront (TLS + caching) → ALB → ECS Fargate
```

| Component | Purpose |
|---|---|
| ECS Fargate | Runs the FastAPI app behind an ALB |
| CloudFront | Edge caching + TLS termination |
| ACM | TLS certificate for the custom domain (us-east-1) |
| Route 53 | DNS alias records pointing to CloudFront |
| Managed prefix list | Locks ALB ingress to CloudFront IPs only |
| GitHub Actions + OIDC | CI/CD pipeline — no stored credentials |

## Prerequisites

- AWS account with a Route 53 hosted zone for your domain
- AWS CLI v2 and Terraform v1.13.4+ with AWS provider v6.20.0+
- Docker Desktop v4.49+
- A GitHub repository for the project
- The GitHub OIDC provider registered in your account (see [OIDC setup](./stop-using-access-keys-github-actions-aws.md))

The examples use `lab.brainyl.cloud`. Replace it with your own domain throughout.

## Step 1: Terraform State Backend

The GitHub Actions runner needs shared Terraform state. Create an S3 bucket with versioning:


```bash
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=us-west-2

aws s3api create-bucket \
  --bucket "tfstate-ecs-cloudfront-${AWS_ACCOUNT_ID}" \
  --region "$AWS_REGION" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION"

aws s3api put-bucket-versioning \
  --bucket "tfstate-ecs-cloudfront-${AWS_ACCOUNT_ID}" \
  --versioning-configuration Status=Enabled
```


## Step 2: The App

A FastAPI app with three routes. The `/static` endpoint returns a fixed JSON payload with `Cache-Control` headers — this is the route that will benefit from CloudFront caching.

Create `main.py`:


```python
from fastapi import FastAPI
from fastapi.responses import HTMLResponse, JSONResponse
import os

app = FastAPI()
version = os.getenv("APP_VERSION", "blue-v1")

@app.get("/health")
def health():
    return {"ok": True, "version": version}

@app.get("/static")
def cloudfront_static():
    """Fixed payload with cache headers — CloudFront will cache this."""
    return JSONResponse(
        content={
            "kind": "cache-friendly",
            "message": "Origin returns Cache-Control; map this path in CloudFront to a cached behavior.",
        },
        headers={"Cache-Control": "public, max-age=3600"},
    )

@app.get("/", response_class=HTMLResponse)
def home():
    color = "#1d4ed8" if "blue" in version.lower() else "#15803d"
    return f"""
    <html><body style='font-family: sans-serif; text-align: center; margin-top: 4rem;'>
      <h1 style='color:{color};'>ECS Blue/Green Demo</h1>
      <p>Current version: <strong>{version}</strong></p>
      <p><a href="/static">/static</a> — JSON with long cache TTL (CloudFront-friendly)</p>
    </body></html>
    """
```


Create `pyproject.toml`:


```toml
[project]
name = "ecs-bluegreen-fastapi"
version = "0.1.0"
requires-python = ">=3.12"
dependencies = [
  "fastapi==0.115.5",
  "uvicorn==0.32.1",
]
```


Create `Dockerfile`:


```dockerfile
FROM python:3.12-slim

WORKDIR /app

RUN pip install --no-cache-dir uv
COPY pyproject.toml ./
RUN uv pip install --system .

COPY main.py ./

EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```


## Step 3: Base Infrastructure

This step creates the VPC, ALB, security groups, ECS cluster, and Fargate service. All standard — nothing CloudFront-specific yet.

Create `terraform.tf`:


```terraform
terraform {
  required_version = ">= 1.13.4"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.20.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
  }

  backend "s3" {
    bucket       = "tfstate-ecs-cloudfront-<YOUR_ACCOUNT_ID>"
    key          = "ecs-cloudfront/terraform.tfstate"
    region       = "us-west-2"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.aws_region
}
```


Create `variables.tf`:


```terraform
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "project_name" {
  description = "Project name prefix"
  type        = string
  default     = "app-ecs"
}

variable "app_url" {
  description = "Public URL for app (defaults to ALB DNS if not provided)"
  type        = string
  default     = ""
}

variable "ecs_desired_count" {
  description = "Desired number of app tasks"
  type        = number
  default     = 3
}

variable "ecs_cpu" {
  description = "Fargate CPU units"
  type        = number
  default     = 512
}

variable "ecs_memory" {
  description = "Fargate memory (MiB)"
  type        = number
  default     = 1024
}

variable "app_version" {
  description = "App version label passed to the container"
  type        = string
  default     = "blue-v1"
}

variable "container_image" {
  description = "Container image URI (provided by CI pipeline)"
  type        = string
}

variable "domain_name" {
  description = "Custom domain for the CloudFront distribution (e.g. lab.brainyl.cloud)"
  type        = string
  default     = ""
}
```


The `domain_name` variable defaults to empty. Without it, CloudFront still works using its default `*.cloudfront.net` domain. Pass a domain name when you're ready to attach a custom domain with TLS. Terraform looks up the Route 53 hosted zone automatically from the domain name.

Create `network.tf`:

The ALB security group uses the CloudFront [managed prefix list](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/LocationsOfEdgeServers.html#managed-prefix-list){target="_blank"} instead of an open CIDR block. This means only CloudFront edge IPs can reach the ALB. AWS maintains this list automatically.


```terraform
locals {
  name_prefix = var.project_name
  app_url     = var.app_url != "" ? var.app_url : "http://${aws_lb.app.dns_name}"
  tags = {
    Project = var.project_name
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.19.0"

  name = "${local.name_prefix}-vpc"
  cidr = "10.10.0.0/16"

  azs             = ["${var.aws_region}a", "${var.aws_region}b"]
  public_subnets  = ["10.10.10.0/24", "10.10.11.0/24"]
  private_subnets = ["10.10.20.0/24", "10.10.21.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = local.tags
}

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "ALB access — CloudFront only"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

resource "aws_security_group" "app_service" {
  name        = "${local.name_prefix}-app-sg"
  description = "ECS tasks"
  vpc_id      = module.vpc.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

resource "aws_security_group_rule" "alb_to_app_8000" {
  type                     = "ingress"
  from_port                = 8000
  to_port                  = 8000
  protocol                 = "tcp"
  security_group_id        = aws_security_group.app_service.id
  source_security_group_id = aws_security_group.alb.id
}

resource "aws_lb" "app" {
  name               = "${local.name_prefix}-alb"
  load_balancer_type = "application"
  subnets            = module.vpc.public_subnets
  security_groups    = [aws_security_group.alb.id]
  tags               = local.tags
}

resource "aws_lb_target_group" "app_tg" {
  name                 = "${local.name_prefix}-tg"
  port                 = 8000
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = module.vpc.vpc_id
  deregistration_delay = 10

  health_check {
    path                = "/"
    matcher             = "200-399"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = local.tags
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}
```


Create `ecs.tf`:


```terraform
resource "aws_iam_role" "task_execution" {
  name = "${local.name_prefix}-task-exec"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ecs-tasks.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task_role" {
  name = "${local.name_prefix}-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ecs-tasks.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "task_role_ecs_exec" {
  name = "${local.name_prefix}-task-role-ecs-exec"
  role = aws_iam_role.task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${local.name_prefix}-app"
  retention_in_days = 14
  tags              = local.tags
}

resource "aws_ecs_cluster" "app" {
  name = "${local.name_prefix}-cluster"
  tags = local.tags
}

resource "aws_ecs_task_definition" "app" {
  family                   = "${local.name_prefix}-app-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.ecs_cpu
  memory                   = var.ecs_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task_role.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "app"
      image     = var.container_image
      essential = true
      portMappings = [
        {
          containerPort = 8000
          name          = "app"
          protocol      = "tcp"
          appProtocol   = "http"
        }
      ]
      environment = [
        { name = "APP_VERSION", value = var.app_version }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.app.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "app"
        }
      }
    }
  ])

  tags = local.tags
}

resource "aws_ecs_service" "app" {
  name                   = "${local.name_prefix}-app-service"
  cluster                = aws_ecs_cluster.app.id
  task_definition        = aws_ecs_task_definition.app.arn
  desired_count          = var.ecs_desired_count
  launch_type            = "FARGATE"
  enable_execute_command = true

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.app_service.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app_tg.arn
    container_name   = "app"
    container_port   = 8000
  }

  tags = local.tags
}
```


Create `outputs.tf`:


```terraform
output "alb_dns_name" {
  description = "Public DNS name for the ALB"
  value       = aws_lb.app.dns_name
}

output "production_url" {
  value = "http://${aws_lb.app.dns_name}"
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.app.name
}

output "ecs_service_name" {
  value = aws_ecs_service.app.name
}

output "cloudfront_domain" {
  description = "CloudFront distribution domain"
  value       = aws_cloudfront_distribution.app.domain_name
}

output "cloudfront_url" {
  value = "https://${aws_cloudfront_distribution.app.domain_name}"
}

output "custom_domain_url" {
  value = var.domain_name != "" ? "https://${var.domain_name}" : "N/A — no custom domain configured"
}
```


## Step 4: OIDC Provider and CI Role

The pipeline needs AWS credentials. OIDC federation gives it short-lived tokens scoped to a single repo and branch — no stored access keys.

⚠️ **Caution:** This uses `AdministratorAccess` for simplicity. In production, scope the policy to the specific services Terraform manages. The trust policy already limits access to `refs/heads/main` on a single repository.

Create `oidc/terraform.tf`:


```terraform
terraform {
  required_version = ">= 1.13.4"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.20.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}
```


Create `oidc/variables.tf`:


```terraform
variable "github_org" {
  description = "GitHub organization or username"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}
```


Create `oidc/main.tf`:


```terraform
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [for cert in data.tls_certificate.github.certificates : lookup(cert, "sha1_fingerprint", "")]
}

resource "aws_iam_role" "github_deploy" {
  name                 = "github-oidc-ecs-deploy"
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "power_user" {
  role       = aws_iam_role.github_deploy.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
```


Create `oidc/outputs.tf`:


```terraform
output "role_arn" {
  description = "IAM role ARN for GitHub Actions to assume via OIDC"
  value       = aws_iam_role.github_deploy.arn
}
```


💡 **Tip:** If you already have the OIDC provider from the [OIDC post](./stop-using-access-keys-github-actions-aws.md), import it: `terraform import aws_iam_openid_connect_provider.github arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com`

Deploy the role:


```bash
terraform init
terraform apply \
  -var="github_org=your-org" \
  -var="github_repo=your-repo"
```


Note the role ARN from the output.

## Step 5: Configure Repository Secrets

Go to your GitHub repository → **Settings** → **Secrets and variables** → **Actions**. Add:

| Secret name | Value | Source |
|---|---|---|
| `AWS_ROLE_TO_ASSUME` | Role ARN from Step 4 | `terraform output -raw role_arn` |
| `AWS_ACCOUNT_ID` | Your 12-digit AWS account ID | `aws sts get-caller-identity --query Account --output text` |

No access keys anywhere.

## Step 6: GitHub Actions Workflow

The pipeline authenticates via OIDC, builds and pushes the image to ECR, then runs `terraform apply`.


```yaml
name: deploy-ecs-cloudfront

on:
  push:
    branches: [main]
    paths:
      - "ecs-fargate-deployments-oidc-cloudfront/app/**"
      - "ecs-fargate-deployments-oidc-cloudfront/terraform/**"
      - ".github/workflows/deploy-ecs-fargate-cloudfront.yml"

env:
  AWS_REGION: us-west-2
  ECR_REPO: fastapi-cloudfront
  PROJECT_DIR: ecs-fargate-deployments-oidc-cloudfront
  TF_WORKING_DIR: ecs-fargate-deployments-oidc-cloudfront/terraform

permissions:
  id-token: write
  contents: read

jobs:
  deploy-ecs-fargate-cloudfront:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: ${{ env.TF_WORKING_DIR }}
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Configure AWS credentials via OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_TO_ASSUME }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Login to ECR
        id: ecr-login
        uses: aws-actions/amazon-ecr-login@v2

      - name: Ensure ECR repository exists
        run: |
          aws ecr describe-repositories \
            --repository-names "$ECR_REPO" \
            --region "$AWS_REGION" 2>/dev/null || \
          aws ecr create-repository \
            --repository-name "$ECR_REPO" \
            --region "$AWS_REGION" \
            --encryption-configuration encryptionType=AES256

      - name: Build and push image
        id: build
        working-directory: ${{ env.PROJECT_DIR }}/app
        run: |
          IMAGE_TAG="${GITHUB_SHA::8}"
          IMAGE_URI="${{ secrets.AWS_ACCOUNT_ID }}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}:${IMAGE_TAG}"

          docker buildx build --platform linux/amd64 \
            -t "$IMAGE_URI" \
            --push .

          echo "image_uri=$IMAGE_URI" >> "$GITHUB_OUTPUT"

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.13.4"
          terraform_wrapper: false

      - name: Terraform init
        run: terraform init

      - name: Terraform apply
        run: |
          terraform apply -auto-approve \
            -var="container_image=${{ steps.build.outputs.image_uri }}"

      - name: Wait for deployment steady state
        run: |
          ECS_CLUSTER=$(terraform output -raw ecs_cluster_name 2>/dev/null || echo "app-ecs-cluster")
          ECS_SERVICE=$(terraform output -raw ecs_service_name 2>/dev/null || echo "app-ecs-app-service")

          echo "Waiting for ECS service to reach steady state..."
          aws ecs wait services-stable \
            --cluster "$ECS_CLUSTER" \
            --services "$ECS_SERVICE"
          echo "Deployment complete."

      - name: Print endpoints
        run: |
          echo "ALB: $(terraform output -raw production_url)"
```


Push your code to `main` and watch the pipeline run under the **Actions** tab.

## Step 7: Add CloudFront, ACM, and Route 53

Create `cdn.tf` in the `terraform/` directory. This file handles everything outside the ALB: the CloudFront distribution, an ACM certificate for your custom domain, DNS validation records, and Route 53 alias records.


```terraform
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

data "aws_route53_zone" "app" {
  count = var.domain_name != "" ? 1 : 0
  name  = var.domain_name
}

resource "aws_acm_certificate" "app" {
  count    = var.domain_name != "" ? 1 : 0
  provider = aws.us_east_1

  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = local.tags
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in try(aws_acm_certificate.app[0].domain_validation_options, []) : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id = data.aws_route53_zone.app[0].zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 300
  records = [each.value.record]
}

resource "aws_acm_certificate_validation" "app" {
  count    = var.domain_name != "" ? 1 : 0
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.app[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

resource "aws_cloudfront_distribution" "app" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "${local.name_prefix} ECS distribution"
  price_class     = "PriceClass_100"

  aliases = var.domain_name != "" ? [var.domain_name] : []

  origin {
    domain_name = aws_lb.app.dns_name
    origin_id   = "alb"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "alb"
    viewer_protocol_policy = var.domain_name != "" ? "redirect-to-https" : "allow-all"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]

    forwarded_values {
      query_string = true
      headers      = ["Host", "Origin"]

      cookies {
        forward = "all"
      }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  ordered_cache_behavior {
    path_pattern           = "/static*"
    target_origin_id       = "alb"
    viewer_protocol_policy = var.domain_name != "" ? "redirect-to-https" : "allow-all"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = var.domain_name == ""
    acm_certificate_arn            = var.domain_name != "" ? aws_acm_certificate_validation.app[0].certificate_arn : null
    ssl_support_method             = var.domain_name != "" ? "sni-only" : null
    minimum_protocol_version       = var.domain_name != "" ? "TLSv1.2_2021" : null
  }

  tags = local.tags
}

resource "aws_route53_record" "app_a" {
  count   = var.domain_name != "" ? 1 : 0
  zone_id = data.aws_route53_zone.app[0].zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.app.domain_name
    zone_id                = aws_cloudfront_distribution.app.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "app_aaaa" {
  count   = var.domain_name != "" ? 1 : 0
  zone_id = data.aws_route53_zone.app[0].zone_id
  name    = var.domain_name
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.app.domain_name
    zone_id                = aws_cloudfront_distribution.app.hosted_zone_id
    evaluate_target_health = false
  }
}
```


There's a lot in this file. Here's what matters:

**Two cache behaviors.** The default behavior has `max_ttl = 0` — all non-`/static` requests pass through to the ALB without caching. Dynamic routes stay fresh. The `/static*` behavior honors the origin's `Cache-Control: public, max-age=3600` and caches at edge locations for up to an hour.

**`origin_protocol_policy = "http-only"`.** The ALB listener is on port 80. CloudFront connects to the origin over HTTP. TLS terminates at CloudFront, not the ALB.

**ACM certificate in us-east-1.** CloudFront [requires certificates in us-east-1](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/cnames-and-https-requirements.html){target="_blank"}, even if your ALB runs in another region. The `provider = aws.us_east_1` alias handles this.

**DNS validation is automated.** Terraform creates the CNAME records in Route 53, waits for ACM to validate, then wires the certificate into CloudFront.

**`viewer_protocol_policy` flips to `redirect-to-https`** once a domain is set. Before that, it allows plain HTTP to the `*.cloudfront.net` URL.

**Route 53 [alias records](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/resource-record-sets-choosing-alias-non-alias.html){target="_blank"}** point directly to CloudFront. No CNAME indirection, no extra DNS hop, and they work at the zone apex.

**Everything is conditional on `var.domain_name`.** Leave it empty and you get the CloudFront distribution with its default `*.cloudfront.net` domain. Pass a domain name to get ACM, DNS validation, and Route 53 records. The hosted zone ID is looked up automatically from the domain name using `data "aws_route53_zone"`.

Deploy:


```bash
terraform init
terraform apply -auto-approve \
  -var="container_image=<YOUR_LATEST_IMAGE_URI>"
```


## Step 8: Verify CloudFront Caching

Grab the CloudFront domain and hit `/static` twice:

```bash
CF_DOMAIN=$(cd terraform && terraform output -raw cloudfront_domain)

curl -sI "https://${CF_DOMAIN}/static"
```

First request — cache miss:

```
HTTP/2 200
x-cache: Miss from cloudfront
cache-control: public, max-age=3600
```

Second request — cache hit:

```bash
curl -sI "https://${CF_DOMAIN}/static"
```

```
HTTP/2 200
x-cache: Hit from cloudfront
cache-control: public, max-age=3600
age: 12
```

✅ **Result:** The `X-Cache: Hit from cloudfront` header confirms the response came from an edge location. The `age` header shows how long it's been cached. The origin didn't get a second request.

Now check the default behavior. Hit the home page:

```bash
curl -sI "https://${CF_DOMAIN}/"
```

```
HTTP/2 200
x-cache: Miss from cloudfront
```

Hit it again — still a miss. The default behavior has `max_ttl = 0`, so CloudFront always forwards to the origin. Dynamic routes stay fresh.

You can also confirm the ALB is locked down. Try hitting it directly:

```bash
ALB_DNS=$(cd terraform && terraform output -raw alb_dns_name)
curl -sI --max-time 5 "http://${ALB_DNS}/static"
```

```
curl: (28) Operation timed out after 5001 milliseconds
```

The ALB security group only allows traffic from CloudFront's managed prefix list, so direct access times out. CloudFront is the only way in.

## Step 9: Deploy with Custom Domain

Deploy with your domain name. Terraform looks up the Route 53 hosted zone automatically:


```bash
terraform apply -auto-approve \
  -var="container_image=<YOUR_LATEST_IMAGE_URI>" \
  -var="domain_name=lab.brainyl.cloud"
```


⚠️ **Caution:** ACM certificate validation can take a few minutes. Terraform will wait for the validation to complete before updating CloudFront. If it times out, run `terraform apply` again — the validation records are already in place.

## Step 10: Verify

Once the deploy finishes, test the full chain:

```bash
curl -sI "https://lab.brainyl.cloud/"
```

```
HTTP/2 200
x-cache: Miss from cloudfront
```

```bash
curl -sI "https://lab.brainyl.cloud/static"
```

```
HTTP/2 200
x-cache: Miss from cloudfront
cache-control: public, max-age=3600
```

Hit `/static` again:

```bash
curl -sI "https://lab.brainyl.cloud/static"
```

```
HTTP/2 200
x-cache: Hit from cloudfront
age: 8
```

✅ **Result:** Your app is live at your custom domain with TLS. The `/static` route is cached at the edge. The ALB is unreachable directly. All traffic flows through CloudFront.

Confirm the DNS records:

```bash
dig lab.brainyl.cloud A +short
dig lab.brainyl.cloud AAAA +short
```

Both should resolve to CloudFront edge IPs.

## Repository Layout

Your final repository should look like this:

```
.
├── .github/
│   └── workflows/
│       └── deploy-ecs-fargate-cloudfront.yml
└── ecs-fargate-deployments-oidc-cloudfront/
    ├── app/
    │   ├── Dockerfile
    │   ├── main.py
    │   └── pyproject.toml
    ├── oidc/
    │   ├── terraform.tf
    │   ├── variables.tf
    │   ├── main.tf
    │   └── outputs.tf
    └── terraform/
        ├── terraform.tf
        ├── variables.tf
        ├── network.tf
        ├── ecs.tf
        ├── cdn.tf            ← CloudFront, ACM, Route 53
        └── outputs.tf
```

The `cdn.tf` file contains everything CloudFront-related: the distribution, ACM certificate, DNS validation records, and Route 53 alias records. Remove it and you're back to a plain ALB setup.

## Cleanup

Destroy the infrastructure in order:


```bash
terraform destroy -auto-approve \
  -var="container_image=placeholder" \
  -var="domain_name=lab.brainyl.cloud"
```


⚠️ **Caution:** CloudFront distributions can take several minutes to disable and delete. Terraform will wait.

Destroy the OIDC role:


```bash
terraform destroy \
  -var="github_org=your-org" \
  -var="github_repo=your-repo"
```


Delete the state bucket last:

```bash
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws s3 rb "s3://tfstate-ecs-cloudfront-${AWS_ACCOUNT_ID}" --force
```

Resources that bill when idle: the NAT gateway, ALB, and CloudFront distribution. Destroy when you're done testing.

💡 **Tip:** If you imported an existing OIDC provider, remove it from state before destroying: `terraform state rm aws_iam_openid_connect_provider.github`

## Production Notes

**Add WAF:**

- Attach an [AWS WAF WebACL](https://docs.aws.amazon.com/waf/latest/developerguide/web-acl.html){target="_blank"} to the CloudFront distribution. Rate limiting, geo-blocking, and managed rule groups (SQL injection, XSS) all plug in at the edge before traffic reaches your ALB.

**Cache invalidation:**

- When you deploy a new version, stale cached responses can linger until the TTL expires. Add a `aws cloudfront create-invalidation` step to the GitHub Actions workflow for paths that change on every deploy. For the `/static` route with a 1-hour TTL, this is usually fine without invalidation.

**HTTPS between CloudFront and ALB:**

- This setup uses `http-only` for the origin connection. For end-to-end encryption, add an HTTPS listener on the ALB with a second ACM certificate (in the ALB's region) and switch `origin_protocol_policy` to `https-only`.

**Logging:**

- Enable CloudFront [standard logging](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/AccessLogs.html){target="_blank"} to an S3 bucket. This gives you per-request logs including cache hit/miss status, client IP, and response time.

**Custom error pages:**

- Configure CloudFront custom error responses for 5xx errors to show a branded error page instead of the default CloudFront error.

**Multiple origins:**

- CloudFront supports multiple origins with path-based routing. You could serve `/api/*` from ECS and `/assets/*` from an S3 bucket — all behind the same distribution.

## Conclusion

- CloudFront caches your origin's `Cache-Control` responses at edge locations — no application changes required beyond setting the right headers
- The managed prefix list locks the ALB to CloudFront traffic without maintaining a CIDR list yourself
- ACM certificates for CloudFront must live in `us-east-1` — use a provider alias to handle that in Terraform
- Route 53 alias records point to CloudFront with no CNAME indirection and zero additional DNS latency
- The `cdn.tf` file is self-contained — remove it and everything else still works as a plain ALB setup

See also: [ECS Blue/Green Deployments on Fargate](./ecs-blue-green-deployments-on-fargate.md) | [Automate ECS Blue/Green CI/CD with GitHub Actions](./ecs-blue-green-github-actions-ci-cd.md) | [Stop Using Access Keys in GitHub Actions](./stop-using-access-keys-github-actions-aws.md)
