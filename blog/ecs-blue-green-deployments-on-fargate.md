
If you've done blue/green deployments on ECS before, you probably set it up through CodeDeploy. That means an extra service to configure, extra IAM roles to manage, and another deployment pipeline to debug when something breaks at 2 AM.

You don't need it anymore. ECS now handles blue/green natively — you define the strategy directly on the service, and ECS manages the traffic shift between two target groups through your ALB listeners. No CodeDeploy, no appspec files, no deployment groups.

Here you'll build a minimal FastAPI app, push it to ECR, and deploy it on Fargate with native blue/green traffic shifting. Production traffic runs on port 80, the green candidate is validated on port 8080, and ECS handles the cutover.

[![Zero-Downtime Deployments on ECS Fargate with Native Blue/Green](https://img.youtube.com/vi/VEhCOvXaAxM/maxresdefault.jpg)](https://www.youtube.com/watch?v=VEhCOvXaAxM)

## What You'll Build

A single ECS Fargate service running a FastAPI app that renders the current deployment version. The ALB exposes two listeners — production on port 80 and test on port 8080 — backed by separate target groups. When you deploy a new version, ECS spins up green tasks, routes test traffic to them, shifts production traffic to green, and keeps both revisions running side by side during the bake period so you can monitor before blue is torn down.

```
Client :80  → ALB (prod listener)  → Blue target group  → ECS tasks (blue-v1)
Client :8080 → ALB (test listener)  → Green target group → ECS tasks (green-v2)
```

| Component | Purpose |
|---|---|
| FastAPI app | Minimal version UI — shows `blue-v1` or `green-v2` |
| ECR | Container registry for the app image |
| VPC | Public/private subnets across two AZs |
| ALB | Dual listeners for production and test traffic |
| ECS Fargate | Service with `BLUE_GREEN` deployment strategy |

## Why Blue/Green Deployments Matter

Blue/green deployments separate **validation** from **production exposure**. Instead of replacing live tasks in place, you run a new task set (green) beside the current one (blue), verify behavior on a test path, and shift production traffic when you're ready.

Three practical benefits:

- **Safer releases:** catch regressions before users see them
- **Near-zero downtime:** traffic shift is controlled at the load balancer layer
- **Fast rollback:** if the new version misbehaves, route traffic back to blue

For teams shipping often, this is one of the highest-leverage deployment patterns you can adopt.

## Choosing the Right Deployment Mode

| Mode | How it works | Rollback | Complexity |
|---|---|---|---|
| **Rolling** | Replaces tasks in batches | Medium | Low |
| **Linear** | Shifts traffic in equal steps (e.g. 20% every 2 min) | Good | Medium |
| **Canary** | Small initial exposure, then full cutover (e.g. 10% for 5 min → 100%) | Very good | Medium |
| **Blue/Green** | Two task sets; validate green on a test listener, then shift production traffic | Excellent | Medium–High |

Use **rolling** for simplicity, **linear** for controlled ramp, **canary** for high-risk changes, and **blue/green** when clean cutover and rollback are the priority.

## Prerequisites

- AWS account with permissions to create VPC, ALB, ECR, ECS, IAM roles, and CloudWatch log groups
- AWS CLI v2 configured with a working profile
- Terraform v1.13.4+ with the AWS provider v6.20.0+
- Docker Desktop v4.49+ with Buildx support
- `curl` for validation commands

⚠️ **Caution:** This lab creates an ECS cluster, NAT gateway, and ALB — all of which bill while running. Destroy resources when you're done.

## Step 1: FastAPI App

The app is intentionally minimal. It reads an `APP_VERSION` environment variable and renders it as a colored heading — blue for blue versions, green for green versions. The `/health` endpoint gives the ALB target group something to check.

### App source


```python
from fastapi import FastAPI
from fastapi.responses import HTMLResponse
import os

app = FastAPI()
version = os.getenv("APP_VERSION", "blue-v1")

@app.get("/health")
def health():
    return {"ok": True, "version": version}

@app.get("/", response_class=HTMLResponse)
def home():
    color = "#1d4ed8" if "blue" in version.lower() else "#15803d"
    return f"""
    <html><body style='font-family: sans-serif; text-align: center; margin-top: 4rem;'>
      <h1 style='color:{color};'>ECS Blue/Green Demo</h1>
      <p>Current version: <strong>{version}</strong></p>
    </body></html>
    """
```


### Dependencies

This uses `uv` for fast dependency installation inside the container.


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


### Dockerfile


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


## Step 2: Build and Push the Blue Image

The ECS task definition references a container image in ECR. You need that image to exist before Terraform can deploy the service.


```bash
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=us-west-2
REPO=fastapi-bluegreen

aws ecr create-repository --repository-name "$REPO" --region "$AWS_REGION" 2>/dev/null || true

aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

# Build and push the initial blue image
docker buildx build --platform linux/amd64 \
  -t "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$REPO:blue-v1" \
  --push .
```


Note the image URI — you'll reference it in `terraform.tfvars` in the next step.

## Step 3: Terraform Base Files

With the image in ECR, set up the Terraform configuration. Replace `<YOUR_ACCOUNT_ID>` with the account ID from the previous step.


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
}

provider "aws" {
  region = var.aws_region
}
```



```terraform
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "project_name" {
  description = "Project name prefix"
  type        = string
  default     = "ecs-bluegreen"
}

variable "admin_cidr" {
  description = "CIDR block allowed to access the ALB"
  type        = string
  default     = "0.0.0.0/0"
}

variable "ecs_desired_count" {
  description = "Desired number of app tasks"
  type        = number
  default     = 1
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

variable "container_image" {
  description = "Container image URI for FastAPI app"
  type        = string
  default     = "<YOUR_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/fastapi-bluegreen:blue-v1"
}

variable "app_version" {
  description = "Version marker shown in app UI"
  type        = string
  default     = "blue-v1"
}
```



```terraform
container_image = "<YOUR_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/fastapi-bluegreen:blue-v1"
app_version     = "blue-v1"
```


## Step 4: Network + ALB with Dual Listeners

This creates the VPC, security groups, ALB, two target groups (blue and green), and two listeners — production on port 80 and test on port 8080.

The dual listener setup is what makes native blue/green work. ECS uses the test listener to route traffic to new green tasks during deployment, and the production listener to serve stable traffic. Once validation passes, ECS shifts production traffic to green and enters the bake period — both revisions run simultaneously so you can monitor before ECS tears down blue.


```terraform
locals {
  name_prefix = var.project_name
  app_url   = var.app_url != "" ? var.app_url : "http://${aws_lb.app.dns_name}"
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

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "ALB access"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

resource "aws_security_group" "ecs" {
  name        = "${local.name_prefix}-ecs-sg"
  description = "ECS tasks"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

resource "aws_lb" "app" {
  name               = "${local.name_prefix}-alb"
  load_balancer_type = "application"
  subnets            = module.vpc.public_subnets
  security_groups    = [aws_security_group.alb.id]
  tags               = local.tags
}

resource "aws_lb_target_group" "blue_app_tg" {
  name        = "${local.name_prefix}-blue-tg"
  port        = 8000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = module.vpc.vpc_id

  health_check {
    path                = "/"
    matcher             = "200-399"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = local.tags
}

resource "aws_lb_listener" "blue_http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.green_app_tg.arn
  }

  lifecycle {
    ignore_changes = [default_action]
  }
}

resource "aws_lb_target_group" "green_app_tg" {
  name        = "${local.name_prefix}-green-tg"
  port        = 8000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = module.vpc.vpc_id

  health_check {
    path                = "/"
    matcher             = "200-399"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = local.tags
}

# Test listener (port 8080) - forwards to green TG for validating before production shift
resource "aws_lb_listener" "green_http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 8080
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.green_app_tg.arn
  }

  lifecycle {
    ignore_changes = [default_action]
  }
}

# Test listener rule - ECS modifies this during blue/green deployment
resource "aws_lb_listener_rule" "test" {
  listener_arn = aws_lb_listener.green_http.arn
  priority     = 1

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.green_app_tg.arn
  }

  condition {
    path_pattern {
      values = ["/", "/*"]
    }
  }

  lifecycle {
    ignore_changes = [action]
  }
}

# Production listener rule - ECS modifies this during blue/green deployment
resource "aws_lb_listener_rule" "production" {
  listener_arn = aws_lb_listener.blue_http.arn
  priority     = 1

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.blue_app_tg.arn
  }

  condition {
    path_pattern {
      values = ["/", "/*"]
    }
  }

  lifecycle {
    ignore_changes = [action]
  }
}
```


### How the Listener Rules Drive Traffic Separation

The listener rules are the mechanism that makes blue/green traffic separation work. ALB evaluates rules by priority — lower numbers win. Here's how the two listeners are configured:

**Production listener (port 80):**

- **Priority 1 rule** → forwards to the **blue** target group
- **Default action** → forwards to the **green** target group

During steady state, every request matches the priority 1 rule first, so all production traffic lands on blue tasks. The default action pointing to green never fires — but it exists because ALB requires a default action on every listener. During cutover, ECS modifies the priority 1 rule to point to the green target group, and production traffic shifts instantly.

**Test listener (port 8080):**

- **Priority 1 rule** → forwards to the **green** target group
- **Default action** → forwards to the **green** target group

This listener exists purely for pre-cutover validation. When ECS starts a blue/green deployment, it registers the new (green) tasks in the green target group. You hit port 8080 to verify the green candidate is healthy and returning expected responses — completely separate from production traffic on port 80. If the green version has a bug, production users never see it.

💡 **Tip:** ECS owns the listener rules at runtime. It modifies the target group associations on both rules during the deployment lifecycle. That's why the `production_listener_rule` and `test_listener_rule` ARNs are passed into the service's `advanced_configuration` block — ECS needs to know which rules to manipulate.

### Why `ignore_changes` on Listeners and Rules

Every listener and listener rule above includes `lifecycle { ignore_changes }`. This is critical for blue/green to work across repeated `terraform apply` runs.

ECS modifies the listener rule actions during deployment — swapping which target group the production and test rules point to. Without `ignore_changes`, the next `terraform apply` detects drift between the Terraform state and what ECS set at runtime, and reverts the rules back to their original target groups. That causes both listeners to flip-flop between blue and green, breaking traffic separation.

With `ignore_changes = [action]` on the rules and `ignore_changes = [default_action]` on the listeners, Terraform creates the initial configuration but hands control to ECS from that point forward. This is the intended ownership model — Terraform manages the infrastructure, ECS manages the traffic routing.

## Step 5: ECS Service with Native Blue/Green

This is the core of the playbook. The ECS service uses `deployment_configuration.strategy = "BLUE_GREEN"` to tell ECS to manage two task sets and shift traffic between them through the ALB listener rules.

Key configuration points:

- `strategy = "BLUE_GREEN"` enables native blue/green without CodeDeploy
- `bake_time_in_minutes = 5` keeps both revisions running for 5 minutes after production traffic shifts to green, giving you time to monitor before blue is torn down
- `alternate_target_group_arn` tells ECS which target group receives the green tasks
- `production_listener_rule` and `test_listener_rule` are the ALB rules ECS swaps during cutover
- `role_arn` is the ECS infrastructure role that has permission to modify ALB listener rules


```terraform
resource "aws_iam_role" "task_execution" {
  name = "${local.name_prefix}-task-exec"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
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
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
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
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup"
        ]
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

resource "aws_security_group" "app_service" {
  name   = "${local.name_prefix}-app-sg"
  vpc_id = module.vpc.vpc_id

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

resource "aws_iam_role" "ecs_infra" {
  name = "${local.name_prefix}-ecs-infra"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "ecs.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ecs_infra" {
  role       = aws_iam_role.ecs_infra.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonECSInfrastructureRolePolicyForLoadBalancers"
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
    target_group_arn = aws_lb_target_group.blue_app_tg.arn
    container_name   = "app"
    container_port   = 8000
    advanced_configuration {
      alternate_target_group_arn  = aws_lb_target_group.green_app_tg.arn
      production_listener_rule    = aws_lb_listener_rule.production.arn
      test_listener_rule          = aws_lb_listener_rule.test.arn
      role_arn                    = aws_iam_role.ecs_infra.arn
    }
  }

  deployment_configuration {
    strategy = "BLUE_GREEN"
    bake_time_in_minutes    = 5
  }

  tags = local.tags
}
```


### The ECS Infrastructure Role — Why It's Required

The `ecs_infra` role is what gives ECS permission to perform the traffic flip. During a blue/green deployment, ECS needs to modify the ALB listener rules — changing which target group the production and test rules point to. Without this role, the deployment fails because the ECS service has no authority to touch the load balancer configuration.

The role trusts the `ecs.amazonaws.com` service principal (not `ecs-tasks.amazonaws.com` — that's for task-level permissions). The attached `AmazonECSInfrastructureRolePolicyForLoadBalancers` managed policy grants the specific Elastic Load Balancing actions ECS needs: modifying listener rules, describing target groups, and registering/deregistering targets.

This is passed into the service via `role_arn` inside the `advanced_configuration` block. If you forget this role or scope the policy too tightly, ECS will accept the deployment but fail silently when it tries to shift traffic.

⚠️ **Caution:** The managed policy is permissive across all ALB resources. In production, replace it with a custom policy scoped to the specific listener rule ARNs and target group ARNs your service uses.


```terraform
output "production_url" {
  value = "http://${aws_lb.app.dns_name}"
}

output "test_url" {
  value = "http://${aws_lb.app.dns_name}:8080"
}
```


## Step 6: Deploy the Infrastructure


```bash
terraform init
terraform fmt
terraform plan -out tfplan
terraform apply tfplan
```


ECS will pull the `blue-v1` image from ECR, start the Fargate tasks, and register them in the blue target group. The production listener on port 80 forwards to blue.

## Step 7: Validate Production and Test Listeners


```bash
PROD_URL=$(terraform output -raw production_url)
TEST_URL=$(terraform output -raw test_url)

echo "PROD_URL=$PROD_URL"
echo "TEST_URL=$TEST_URL"

curl -fsS "$PROD_URL/" | sed -n '1,5p'
curl -fsS "$TEST_URL/" | sed -n '1,5p' || true
```


✅ **Result:** After the first deploy:

- `production_url` (`:80`) shows `blue-v1`
- `test_url` (`:8080`) returns nothing useful yet — it only shows the green candidate during an active deployment

## Step 8: Roll Out Green and Shift Traffic

Now deploy a new version. This is where native blue/green earns its keep.

### Build and push the green image


```bash
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=us-west-2
REPO=fastapi-bluegreen

docker buildx build --platform linux/amd64 \
  -t "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$REPO:green-v2" \
  --push .
```


### Update `terraform.tfvars`

Point the service to the new image:

```terraform
container_image = "<YOUR_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/fastapi-bluegreen:green-v2"
app_version     = "green-v2"
```

### Apply the update


```bash
terraform plan -out tfplan-green
terraform apply tfplan-green
```


### Observe the rollout

During deployment, ECS spins up green tasks and registers them in the green target group. The test listener on port 8080 routes to green, while production on port 80 stays on blue.


```bash
PROD_URL=$(terraform output -raw production_url)
TEST_URL=$(terraform output -raw test_url)

echo "=== Test listener (should show green candidate) ==="
curl -fsS "$TEST_URL/" | sed -n '1,8p' || true

echo "=== Production (should still be blue until cutover) ==="
curl -fsS "$PROD_URL/" | sed -n '1,8p'

echo "=== Production after bake period ==="
sleep 30
curl -fsS "$PROD_URL/" | sed -n '1,8p'
```


✅ **Result:** After the bake period completes, `production_url` returns `green-v2`. The traffic shift happened at the ALB layer — no task restarts, no dropped connections.

## Step 9: Rollback Path

Two scenarios:

**During bake period:** Production traffic is already on green, but blue is still running. Cancel the deployment and ECS shifts traffic back to blue immediately. Green tasks are drained and stopped.

**After bake completes:** Blue has been torn down. Re-deploy the previous image tag — update `terraform.tfvars` back to `blue-v1`, run `terraform apply`, and ECS runs the same blue/green cycle in reverse. The old version becomes the new green candidate, gets validated, and shifts back into production.

Either path gives you a deterministic rollback with no manual ALB reconfiguration.

## Cleanup


```bash
terraform destroy -auto-approve
```


💡 **Tip:** The ECS cluster, NAT gateway, and ALB all bill while running. Don't forget to clean up the ECR repository separately if you no longer need it:

```bash
aws ecr delete-repository --repository-name fastapi-bluegreen --force --region us-west-2
```

## Production Notes

**IAM hardening:**

- The example uses broad managed policies for the task execution and ECS infrastructure roles. In production, scope these down to the specific ECR repositories, log groups, and ALB resources your service needs.

**Bake time tuning:**

- The bake period starts *after* production traffic shifts to green — both revisions run side by side during this window. Five minutes is a starting point. Set this based on how long your monitoring and alerting need to detect regressions. Longer bake times give you more confidence but slow down your deployment cadence.

**Lifecycle hooks:**

- ECS supports [deployment lifecycle hooks](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/deployment-lifecycle-hooks.html) — Lambda functions that run at specific stages between blue and green (pre-scale-up, post-scale-up, test traffic shift, production traffic shift, and more). Use them to run automated smoke tests, validate health checks, or gate cutover on external signals. If the hook returns `FAILED`, ECS rolls back automatically.

**HTTPS:**

- This lab uses HTTP listeners for simplicity. For production, attach an ACM certificate and use HTTPS on both the production and test listeners.

**Database migrations:**

- This playbook intentionally excludes databases. If your service has a data layer, you'll need to handle schema migrations separately — run them before the deployment starts, and make sure they're backward-compatible with both the blue and green versions.

**CI/CD integration:**

- Pair this with [OIDC-based GitHub Actions](./stop-using-access-keys-github-actions-aws.md) to automate the image build, push, and `terraform apply` steps without long-lived access keys.

## Conclusion

- Native ECS blue/green removes the CodeDeploy dependency — the deployment strategy lives in the service definition
- Dual ALB listeners give you a clean separation between production traffic and green candidate validation
- The bake period keeps both revisions running after production cutover — a built-in safety window to monitor before blue is torn down
- Rollback is straightforward: cancel during bake to shift traffic back to blue, or re-deploy the previous image tag
