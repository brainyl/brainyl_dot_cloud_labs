
In [Multi-Service ECS: Add a Webhook Receiver to Ghost on Fargate](./ghost-ecs-fargate-webhooks.md), Ghost and webhooks shared one task and communicated over localhost.

In [Multi-Service ECS: Split Ghost and Webhooks with Cloud Map and Route 53 Service Discovery](./ghost-ecs-fargate-service-discovery.md), you split them into separate services and connected them with service discovery DNS.

In this post, you solve the same split-service problem with **ECS Service Connect**.

<iframe width="776" height="437" src="https://player.vimeo.com/video/1169210167" title="Connect Ghost and Webhooks with ECS Service Connect" frameborder="0" allow="autoplay; fullscreen; picture-in-picture; clipboard-write; encrypted-media" allowfullscreen></iframe>

## What You’ll Build

- Full baseline infrastructure (VPC, ALB, Aurora) in this same post
- Webhook receiver image build + ECR push
- Two ECS services (`ghost-service`, `webhooks-service`)
- Service Connect-managed service-to-service communication
- Ghost calling webhooks privately at `http://webhooks.dev:8000/webhook`

## Why Service Connect

Service Connect builds on Cloud Map and adds a managed connection layer in ECS. Instead of wiring app-to-app DNS and traffic handling manually, ECS injects a managed proxy container into each task and routes service traffic through it.

Per AWS docs, this proxy container is added automatically (not declared in your task definition), and handles service endpoint routing plus traffic features like retries and round-robin behavior.

- https://docs.aws.amazon.com/AmazonECS/latest/developerguide/service-connect-concepts.html
- https://docs.aws.amazon.com/AmazonECS/latest/developerguide/service-connect.html

## Step 1: Create Terraform base files

Start with the Terraform scaffolding and shared variables. These define region, naming, Ghost runtime sizing, and default URL behavior used throughout the rest of the lab.

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
  default     = "ghost-ecs"
}

variable "ghost_url" {
  description = "Public URL for Ghost (defaults to ALB DNS if not provided)"
  type        = string
  default     = ""
}

variable "admin_cidr" {
  description = "CIDR block allowed to access the ALB"
  type        = string
  default     = "0.0.0.0/0"
}

variable "db_name" {
  description = "Ghost database name"
  type        = string
  default     = "ghost_production"
}

variable "db_username" {
  description = "Ghost database username"
  type        = string
  default     = "ghostadmin"
}

variable "ecs_desired_count" {
  description = "Desired number of Ghost tasks"
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
```


```terraform
# Optional: Set ghost_url if using a custom domain
# ghost_url = "https://blog.example.com"

# If not set, defaults to http://<alb-dns-name>
```


## Step 2: Create network + database + load balancer

This block brings up the baseline platform from the earlier posts: VPC/subnets, security groups, Aurora Serverless v2, and an ALB in front of Ghost. Keeping this here makes the post fully runnable without having to stitch files from multiple articles.

```terraform
locals {
  name_prefix = var.project_name
  ghost_url   = var.ghost_url != "" ? var.ghost_url : "http://${aws_lb.ghost.dns_name}"
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
    from_port       = 2368
    to_port         = 2368
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

resource "aws_security_group" "db" {
  name        = "${local.name_prefix}-db-sg"
  description = "Aurora access"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ghost_service.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}


resource "random_password" "db" {
  length  = 24
  special = true
}

resource "aws_secretsmanager_secret" "db" {
  name = "${local.name_prefix}-db-credentials"
  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id     = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
    dbname   = var.db_name
  })
}

resource "aws_db_subnet_group" "ghost" {
  name       = "${local.name_prefix}-db-subnets"
  subnet_ids = module.vpc.private_subnets
  tags       = local.tags
}

resource "aws_rds_cluster" "ghost" {
  cluster_identifier      = "${local.name_prefix}-aurora"
  engine                  = "aurora-mysql"
  engine_version          = "8.0.mysql_aurora.3.11.1"
  database_name           = var.db_name
  master_username         = var.db_username
  master_password         = random_password.db.result
  db_subnet_group_name    = aws_db_subnet_group.ghost.name
  vpc_security_group_ids  = [aws_security_group.db.id]
  storage_encrypted       = true
  skip_final_snapshot     = true

  serverlessv2_scaling_configuration {
    min_capacity = 0.5
    max_capacity = 2
  }

  tags = local.tags
}

resource "aws_rds_cluster_instance" "ghost" {
  identifier         = "${local.name_prefix}-aurora-instance"
  cluster_identifier = aws_rds_cluster.ghost.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.ghost.engine
  engine_version     = aws_rds_cluster.ghost.engine_version
  publicly_accessible = false
  tags               = local.tags
}

resource "aws_lb" "ghost" {
  name               = "${local.name_prefix}-alb"
  load_balancer_type = "application"
  subnets            = module.vpc.public_subnets
  security_groups    = [aws_security_group.alb.id]
  tags               = local.tags
}

resource "aws_lb_target_group" "ghost" {
  name        = "${local.name_prefix}-tg"
  port        = 2368
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

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.ghost.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ghost.arn
  }
}
```


## Step 3: Create webhook receiver + ECR definition

Next you define the webhook app source and container image config, then add an ECR repository to store that image. This gives ECS a stable image source for the dedicated `webhooks-service` task.

```python
from fastapi import FastAPI, Request
import logging

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

app = FastAPI(title="Webhook Receiver")


@app.get("/")
async def root():
    return {"message": "Webhook receiver is running"}


@app.post("/webhook")
async def handle_webhook(request: Request):
    """
    Receives webhook POST requests and logs headers and body
    """
    # Get all headers
    headers = dict(request.headers)
    
    # Get the body
    body = await request.body()
    
    # Try to parse as JSON, fallback to raw text
    try:
        json_body = await request.json()
        logger.info("=" * 50)
        logger.info("WEBHOOK RECEIVED")
        logger.info("=" * 50)
        logger.info(f"Received Headers: {headers}")
        logger.info(f"Body (JSON): {json_body}")
        logger.info("=" * 50)
        
        return {
            "status": "success",
            "message": "Webhook received",
            "headers": headers,
            "body": json_body
        }
    except:
        logger.info("=" * 50)
        logger.info("WEBHOOK RECEIVED")
        logger.info("=" * 50)
        logger.info(f"Received Headers: {headers}")
        logger.info(f"Body (raw): {body.decode('utf-8', errors='ignore')}")
        logger.info("=" * 50)
        
        return {
            "status": "success",
            "message": "Webhook received",
            "headers": headers,
            "body": body.decode('utf-8', errors='ignore')
        }


@app.get("/health")
async def health_check():
    return {"status": "healthy"}
```


```
fastapi==0.109.0
uvicorn==0.27.0
```


```dockerfile
FROM python:3.11-slim

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

WORKDIR /app

COPY requirements.txt .

RUN uv pip install --system --no-cache -r requirements.txt

COPY app.py .

EXPOSE 8000

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
```


```terraform
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
```


## Step 4: Create split-services ECS configuration

This is the key change in this post. Ghost and webhooks remain separate ECS services, but connectivity is handled by ECS Service Connect-managed proxies instead of direct DNS calls. You still need an ingress rule allowing Ghost tasks to reach the webhooks task ENI on port 8000.


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

resource "aws_iam_role_policy" "task_execution_secrets" {
  name = "${local.name_prefix}-task-exec-secrets"
  role = aws_iam_role.task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = aws_secretsmanager_secret.db.arn
      }
    ]
  })
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

resource "aws_cloudwatch_log_group" "ghost" {
  name              = "/ecs/${local.name_prefix}-ghost"
  retention_in_days = 14
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "webhooks" {
  name              = "/ecs/${local.name_prefix}-webhooks"
  retention_in_days = 14
  tags              = local.tags
}

resource "aws_ecs_cluster" "ghost" {
  name = "${local.name_prefix}-cluster"
  tags = local.tags
}

resource "aws_service_discovery_http_namespace" "sc" {
  name = "${local.name_prefix}-sc"
  tags = local.tags
}

resource "aws_security_group" "ghost_service" {
  name   = "${local.name_prefix}-ghost-sg"
  vpc_id = module.vpc.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

resource "aws_security_group" "webhooks_service" {
  name   = "${local.name_prefix}-webhooks-sg"
  vpc_id = module.vpc.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

resource "aws_security_group_rule" "alb_to_ghost_2368" {
  type                     = "ingress"
  from_port                = 2368
  to_port                  = 2368
  protocol                 = "tcp"
  security_group_id        = aws_security_group.ghost_service.id
  source_security_group_id = aws_security_group.alb.id
}

resource "aws_security_group_rule" "ghost_to_webhooks_8000" {
  type                     = "ingress"
  from_port                = 8000
  to_port                  = 8000
  protocol                 = "tcp"
  security_group_id        = aws_security_group.webhooks_service.id
  source_security_group_id = aws_security_group.ghost_service.id
}

resource "aws_ecs_task_definition" "ghost" {
  family                   = "${local.name_prefix}-ghost-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.ecs_cpu
  memory                   = var.ecs_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task_role.arn

  container_definitions = jsonencode([
    {
      name      = "ghost"
      image     = "ghost:6.1.0"
      essential = true
      portMappings = [
        {
          containerPort = 2368
          name          = "ghost"
          protocol      = "tcp"
          appProtocol   = "http"
        }
      ]
      environment = [
        { name = "url", value = local.ghost_url },
        { name = "database__client", value = "mysql" },
        { name = "database__connection__host", value = aws_rds_cluster.ghost.endpoint },
        { name = "database__connection__port", value = "3306" },
        { name = "database__connection__user", value = var.db_username },
        { name = "database__connection__database", value = var.db_name },
        { name = "logging__level", value = "info" }
      ]
      secrets = [
        {
          name      = "database__connection__password"
          valueFrom = "${aws_secretsmanager_secret.db.arn}:password::"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ghost.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ghost"
        }
      }
    }
  ])

  tags = local.tags
}

resource "aws_ecs_task_definition" "webhooks" {
  family                   = "${local.name_prefix}-webhooks-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task_role.arn

  container_definitions = jsonencode([
    {
      name      = "webhooks"
      image     = "${aws_ecr_repository.webhook.repository_url}:latest"
      essential = true
      portMappings = [
        {
          containerPort = 8000
          name          = "webhooks"
          protocol      = "tcp"
          appProtocol   = "http"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.webhooks.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "webhooks"
        }
      }
    }
  ])

  tags = local.tags
}

resource "aws_ecs_service" "ghost" {
  name                   = "${local.name_prefix}-ghost-service"
  cluster                = aws_ecs_cluster.ghost.id
  task_definition        = aws_ecs_task_definition.ghost.arn
  desired_count          = var.ecs_desired_count
  launch_type            = "FARGATE"
  enable_execute_command = true

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.ghost_service.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.ghost.arn
    container_name   = "ghost"
    container_port   = 2368
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.sc.arn
  }

  tags = local.tags
}

resource "aws_ecs_service" "webhooks" {
  name            = "${local.name_prefix}-webhooks-service"
  cluster         = aws_ecs_cluster.ghost.id
  task_definition = aws_ecs_task_definition.webhooks.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.webhooks_service.id]
    assign_public_ip = false
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.sc.arn

    service {
      discovery_name = "webhooks"
      port_name      = "webhooks"

      client_alias {
        port     = 8000
        dns_name = "webhooks"
      }
    }
  }

  tags = local.tags
}
```


## Step 5: Create outputs

```terraform
output "alb_dns_name" {
  description = "Public DNS name for the ALB"
  value       = aws_lb.ghost.dns_name
}

output "alb_target_group_arn" {
  description = "ALB target group ARN for Ghost"
  value       = aws_lb_target_group.ghost.arn
}

output "db_endpoint" {
  description = "Aurora cluster endpoint"
  value       = aws_rds_cluster.ghost.endpoint
}

output "ghost_url" {
  description = "Ghost URL configured in the container"
  value       = local.ghost_url
}

```


## Step 6: Build and push webhook image

Apply the ECR target first so the repository exists, then build and push the webhook image. ECS will pull this image when creating the `webhooks` task.


```bash
terraform init
terraform apply -target=aws_ecr_repository.webhook -auto-approve
```



```bash
AWS_REGION=us-west-2
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REPO_NAME=ghost-ecs-webhook-receiver
IMAGE_URI=$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$REPO_NAME:latest

aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

docker buildx build --platform linux/amd64,linux/arm64 -t $IMAGE_URI --push .
```


## Step 7: Deploy full stack

Now deploy everything together. Terraform will provision/update networking, database, ALB, ECR-integrated ECS services, and Cloud Map registration in one apply.


```bash
terraform fmt
terraform init
terraform plan -out tfplan
terraform apply tfplan
```


## Step 8: Configure Ghost webhook URL

Once Ghost is reachable through the ALB, create/update the integration in Ghost Admin and point it to the private service-discovery endpoint below.

Set webhook target in Ghost Admin:

`http://webhooks.dev:8000/webhook`

## Integration UI Reference (from previous post)

Use the same Ghost Admin UI flow from the prior post, but set the webhook target to `http://webhooks.dev:8000/webhook` in this Service Connect lab.

Open **Settings → Integrations**:

![Ghost admin settings showing integrations page](/media/images/2026/02/webhooks/ghost-integrations-page.png)

Click **Add custom integration**:

![Add custom integration button](/media/images/2026/02/webhooks/ghost-add-custom-integration.png)

Name your integration (for example: `Service Connect Webhooks`) and create it:

![Custom integration naming screen](/media/images/2026/02/webhooks/ghost-integration-webhooks-config.png)

Configure the webhook URL and member events:

![Ghost webhook configuration with member events](/media/images/2026/02/webhooks/ghost-webhook-member-events.png)

Trigger a test event to verify delivery:

![Ghost webhook test trigger action](/media/images/2026/02/webhooks/ghost-webhook-test-trigger.png)

Previous post for full UI walkthrough: [/ghost-ecs-fargate-webhooks/](./ghost-ecs-fargate-webhooks.md)

## Step 9: Validate from ECS Exec

Before using ECS Exec, install the AWS Session Manager plugin on your machine (`session-manager-plugin`) and ensure your IAM principal has ECS Exec permissions.

If you want to test connectivity from inside the running Ghost container, use ECS Exec first, then run the checks in-shell:

```bash
aws ecs execute-command \
  --cluster ghost-ecs-cluster \
  --task <ghost-task-id> \
  --container ghost \
  --interactive \
  --command "/bin/bash"

# inside the Ghost container
apt update && apt install -y curl iputils-ping dnsutils jq
curl http://webhooks.dev:8000/health
```


Use ECS commands to verify the Ghost service is running and tasks are healthy before testing webhook events from the Ghost UI.


```bash
aws ecs list-clusters --region us-west-2
aws ecs list-tasks --cluster <your-cluster-name> --service-name <your-name-prefix>-ghost-service --region us-west-2
```


## Cleanup


```bash
terraform destroy -auto-approve
```

