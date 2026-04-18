
In [How to Deploy Ghost CMS on ECS Fargate](./ghost-ecs-fargate.md), you deployed Ghost as a single container on ECS Fargate. AWS manages the runtime, Aurora holds the data, and the ALB handles public traffic. The deployment works, but it only does one thing: serve the blog. Most real workloads need more than one service—a background worker, a webhook handler, a sidecar proxy. How you connect those services together on ECS depends on how tightly coupled they need to be.

Ghost fires webhook events whenever something interesting happens—a member subscribes, a post goes live, someone changes tiers. Those events disappear unless something is listening. You could point them at a Lambda or an external service, but for now the simplest option is a small receiver running next to Ghost in the same ECS task.

That's what you'll build here. You'll add a FastAPI container to the existing task definition so both services share the same network namespace and communicate over `localhost`. No service discovery, no extra ALB rules, no separate deployments. Ghost sends a POST to `localhost:8000/webhook`, and the receiver logs it to CloudWatch.

The coupling is deliberate. Both containers start together, scale together, and restart together. That's fine for prototyping and for services that are genuinely interdependent. When you need independent scaling or separate deployment cycles, you split them into their own tasks. That's the separate-task architecture covered in a future post.

<iframe width="776" height="437" src="https://www.youtube.com/embed/hZwXO2PmAt4" title="Run Multiple Containers with ECS Fargate Task: Ghost CMS + Webhook Receiver with ECR on AWS" frameborder="0" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" allowfullscreen></iframe>

## What You'll Build

You'll add a webhook receiver container to your Ghost ECS task. The webhook service runs FastAPI on port 8000 and logs all incoming POST requests to CloudWatch. Ghost sends member events directly to the webhook container over `localhost:8000` - no ALB routing required.

**Architecture:**

```
Client
  ↓
Application Load Balancer (public subnets)
  ↓
  Ghost container (port 2368)
  ↓
ECS Fargate task (single task, two containers)
  ├─ Ghost (essential) ←→ localhost:8000 ←→ Webhook receiver (non-essential)
  ↓
Aurora Serverless v2 (private subnets)
```

| Component | Purpose |
|-----------|---------|
| Ghost container | Primary service, listens on port 2368, sends webhooks to localhost:8000 |
| Webhook receiver | FastAPI service, listens on port 8000, receives webhooks over localhost |
| Shared task | Both containers run in the same Fargate task and share network namespace |
| Localhost communication | Ghost calls webhook receiver directly without ALB routing |

## Prerequisites

- Completed [How to Deploy Ghost CMS on ECS Fargate](./ghost-ecs-fargate.md)
- Terraform **v1.13.4+** and AWS provider **v6.20.0+**
- AWS CLI **v2**
- Docker Desktop **v4.49+**
- AWS account with ECS, ECR, and CloudWatch Logs permissions
- Region: `us-west-2`

⚠️ Caution: This tutorial extends the existing Ghost ECS stack. Both containers run in the same task and share CPU and memory limits. If one container consumes excessive resources, it affects the other.

## Why Multi-Container Tasks?

ECS lets you run multiple containers in a single task definition. Containers in the same task share the network namespace, lifecycle, resource limits, and IAM roles. They communicate over `localhost` without service discovery, deploy as a single unit with one `terraform apply`, and cost less than running separate tasks.

The trade-off is coupling. If the primary container crashes, ECS replaces the entire task—including every sidecar. You can't scale the webhook receiver independently of Ghost. Updating one container means redeploying both. If one container eats all the CPU, the other starves.

That trade-off is acceptable in two situations: when you're prototyping and want minimal infrastructure complexity, or when the services are genuinely interdependent and always need to run together. Sidecar proxies, log shippers, and internal webhook receivers are common examples. Once you need independent scaling, separate deployment cycles, or resource isolation, it's time to split into separate tasks.

## Step 1: Build the Webhook Receiver

Create a new directory for the webhook service:


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
        logger.info(f"Headers: {headers}")
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
        logger.info(f"Headers: {headers}")
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


The `/webhook` endpoint accepts any POST, logs the headers and body, and returns what it received. Ghost sends JSON payloads with member data—you'll see them in CloudWatch once this is deployed to ECS. The `/health` endpoint gives you a quick way to confirm the receiver is up when debugging.

Create `requirements.txt`:


```
fastapi==0.109.0
uvicorn==0.27.0
```


### Test Locally Before Building the Image

Run the app on your machine first. You want to confirm the endpoints respond correctly and the log output looks right before baking it into a container.

Install dependencies:

```bash
cd labs/ghost-ecs-fargate-terraform/webhook-receiver

# Install uv if you haven't already
curl -LsSf https://astral.sh/uv/install.sh | sh

# Install dependencies in a virtual environment
uv venv
source .venv/bin/activate  # On Windows: .venv\Scripts\activate
uv pip install -r requirements.txt
```

Run the FastAPI server:

```bash
uvicorn app:app --host 0.0.0.0 --port 8000 --reload
```

The server starts at `http://localhost:8000`. The `--reload` flag picks up code changes automatically during development.

**Test the root endpoint:**

```bash
curl http://localhost:8000/
```

Expected response:

```json
{"message": "Webhook receiver is running"}
```

**Test the health check:**

```bash
curl http://localhost:8000/health
```

Expected response:

```json
{"status": "healthy"}
```

**Test the webhook endpoint:**

```bash
curl -X POST http://localhost:8000/webhook \
  -H "Content-Type: application/json" \
  -d '{
    "event": "member.added",
    "data": {
      "email": "test@example.com",
      "name": "Test User"
    }
  }'
```

Expected response:

```json
{
  "status": "success",
  "message": "Webhook received",
  "headers": {...},
  "body": {
    "event": "member.added",
    "data": {
      "email": "test@example.com",
      "name": "Test User"
    }
  }
}
```

Check the terminal running uvicorn. You should see:

```
==================================================
WEBHOOK RECEIVED
==================================================
Headers: {'host': 'localhost:8000', 'user-agent': 'curl/...', 'content-type': 'application/json', ...}
Body (JSON): {'event': 'member.added', 'data': {'email': 'test@example.com', 'name': 'Test User'}}
==================================================
```

That confirms the receiver captures and logs payloads correctly. On ECS, these same logs show up in CloudWatch instead of your terminal.

Stop the server with `Ctrl+C` and deactivate the virtual environment:

```bash
deactivate
```

Now containerize it. Create the `Dockerfile`:


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


Python 3.11 slim helps to keep the image small, and `uv` installs dependencies fast.

## Step 2: Create the ECR Repository

The webhook image needs a home. Add an ECR repository for it. Create `ecr.tf`:


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


Apply to create it:


```bash
terraform apply -auto-approve
```


## Step 3: Build and Push the Webhook Image

Authenticate Docker to ECR and push the webhook image:


```bash
AWS_REGION="us-west-2"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
WEBHOOK_REPO="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/ghost-ecs-webhook-receiver"

# Authenticate Docker to ECR
aws ecr get-login-password --region $AWS_REGION | \
  docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

# Build for x86_64 (Fargate default platform)
docker buildx build --platform linux/amd64 -t webhook-receiver:latest .

# Tag and push
docker tag webhook-receiver:latest $WEBHOOK_REPO:latest
docker push $WEBHOOK_REPO:latest

echo "✓ Pushed: $WEBHOOK_REPO:latest"
```


Verify the image in ECR:


```bash
aws ecr describe-images \
  --repository-name ghost-ecs-webhook-receiver \
  --region us-west-2 \
  --query 'imageDetails[0].{Pushed:imagePushedAt,Digest:imageDigest,Tags:imageTags}'
```


## Step 4: Update the Task Definition

Now you add the webhook container to the existing Ghost task definition. Both containers share the task's CPU and memory allocation (512 CPU units and 1024 MiB by default)—no additional Fargate cost beyond what you're already paying.

Replace the existing `ecs.tf` with this updated version. The only changes from the original are the new `aws_cloudwatch_log_group.webhook` resource and the second container in the task definition:


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
        Resource = [aws_secretsmanager_secret.db.arn]
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "ghost" {
  name              = "/ecs/${local.name_prefix}"
  retention_in_days = 14
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "webhook" {
  name              = "/ecs/${local.name_prefix}-webhook"
  retention_in_days = 7
  tags              = local.tags
}

resource "aws_ecs_cluster" "ghost" {
  name = "${local.name_prefix}-cluster"
  tags = local.tags
}

resource "aws_ecs_task_definition" "ghost" {
  family                   = "${local.name_prefix}-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.ecs_cpu
  memory                   = var.ecs_memory
  execution_role_arn       = aws_iam_role.task_execution.arn

  container_definitions = jsonencode([
    {
      name      = "ghost"
      image     = "ghost:6.1.0"
      essential = true
      portMappings = [
        {
          containerPort = 2368
          hostPort      = 2368
          protocol      = "tcp"
        }
      ]
      environment = [
        {
          name  = "url"
          value = local.ghost_url
        },
        {
          name  = "database__client"
          value = "mysql"
        },
        {
          name  = "database__connection__host"
          value = aws_rds_cluster.ghost.endpoint
        },
        {
          name  = "database__connection__port"
          value = "3306"
        },
        {
          name  = "database__connection__user"
          value = var.db_username
        },
        {
          name  = "database__connection__database"
          value = var.db_name
        },
        {
          name  = "logging__level"
          value = "info"
        }
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
    },
    {
      name      = "webhook-receiver"
      image     = "${aws_ecr_repository.webhook.repository_url}:latest"
      essential = false

      portMappings = [
        {
          containerPort = 8000
          hostPort      = 8000
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.webhook.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "webhook"
        }
      }
    }
  ])

  tags = local.tags
}

resource "aws_ecs_service" "ghost" {
  name            = "${local.name_prefix}-service"
  cluster         = aws_ecs_cluster.ghost.id
  task_definition = aws_ecs_task_definition.ghost.arn
  desired_count   = var.ecs_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.ghost.arn
    container_name   = "ghost"
    container_port   = 2368
  }

  depends_on = [
    aws_lb_listener.http,
    aws_rds_cluster_instance.ghost
  ]

  tags = local.tags
}
```


The webhook container is marked `essential = false`. If it crashes, ECS replaces only the webhook container while Ghost keeps running. Ghost stays `essential = true`—if Ghost dies, ECS replaces the entire task. Each container logs to its own CloudWatch log group so you can filter them independently. Only Ghost is registered with the ALB target group. The webhook receiver stays internal—reachable only over `localhost` from within the task.

Notice there are no container-level health checks defined. The ALB already health-checks Ghost on port 2368 via the target group, and the webhook receiver is internal-only. Adding container health checks would require installing tools like `wget` or `curl` in each image—unnecessary complexity for this setup.

### How the Two Containers Talk

ECS tasks using `awsvpc` network mode get a single ENI. Both containers share that ENI and its IP address, so they see each other on `localhost`. Ghost sends a POST to `http://localhost:8000/webhook`, and it never leaves the task. Security group rules don't apply to loopback traffic—they only control what comes in from outside.

```
ECS Task (single ENI: 10.0.1.50)
├─ Ghost container (listens on 0.0.0.0:2368)
│  └─ Sends POST to http://localhost:8000/webhook
│
└─ Webhook container (listens on 0.0.0.0:8000)
   └─ Receives POST from localhost
```

Both containers bind to `0.0.0.0`, which means they technically listen on the task's ENI too. But the ECS security group only opens port 2368 from the ALB. Port 8000 is blocked from outside, so the webhook receiver is unreachable from the network even though it's running. You don't need to add any security group rules for this to work.

💡 Tip: If you later need *other tasks* to reach the webhook receiver, you'd add a self-referencing security group rule on port 8000, switch Ghost to use the task's private IP instead of `localhost`, and set up service discovery. That's the separate-task architecture covered in a future post. For now, `localhost` is all you need.

## Step 5: Deploy the Multi-Container Task

Apply the Terraform changes:


```bash
terraform apply -auto-approve
```


ECS registers a new task revision and performs a rolling deployment: it starts a new task with both containers, waits for the ALB target to become healthy, then drains the old one.

Monitor the rollout:


```bash
aws ecs describe-services \
  --cluster ghost-ecs-cluster \
  --services ghost-ecs-service \
  --region us-west-2 \
  --query 'services[0].{RunningCount:runningCount,DesiredCount:desiredCount,Status:status,Deployments:deployments[*].{Status:status,TaskDef:taskDefinition}}'
```


Wait for `runningCount` to match `desiredCount` and the primary deployment to show `PRIMARY`.

Check that both containers are running:


```bash
TASK_ARN=$(aws ecs list-tasks \
  --cluster ghost-ecs-cluster \
  --service-name ghost-ecs-service \
  --region us-west-2 \
  --query 'taskArns[0]' \
  --output text)

aws ecs describe-tasks \
  --cluster ghost-ecs-cluster \
  --tasks $TASK_ARN \
  --region us-west-2 \
  --query 'tasks[0].containers[*].{Name:name,Status:lastStatus,Health:healthStatus}'
```


Expected output:

```json
[
  {
    "Name": "ghost",
    "Status": "RUNNING",
    "Health": "UNKNOWN"
  },
  {
    "Name": "webhook-receiver",
    "Status": "RUNNING",
    "Health": "UNKNOWN"
  }
]
```

`Health: UNKNOWN` means no container-level health check is defined—that's expected. The ALB health check covers Ghost separately.

## Step 6: Configure Ghost Webhooks

Open Ghost admin at `http://<your-alb-dns>/ghost` and set up an admin account if you haven't already. Then head to **Settings → Integrations** to wire up the webhooks.

### Navigate to Integrations

From the Ghost admin dashboard, click **Settings** in the left sidebar, then select **Integrations**:

![Ghost admin settings showing integrations page](/media/images/2026/02/webhooks/ghost-integrations-page.png)

### Add Custom Integration

Click **Add custom integration**:

![Add custom integration button](/media/images/2026/02/webhooks/ghost-add-custom-integration.png)

### Name Your Integration

Give it a descriptive name like "Member Webhook Logger" and click **Create**:

![Name the custom integration](/media/images/2026/02/webhooks/ghost-integration-webhooks-config.png)

### Configure Webhook URL and Events

Scroll down to the **Webhooks** section. Enter the internal webhook URL and select which events to subscribe to:

**Webhook URL:** `http://localhost:8000/webhook`

![Configure webhook URL and event types](/media/images/2026/02/webhooks/ghost-webhook-member-events.png)

Since both containers share the network namespace, Ghost reaches the webhook receiver on `localhost:8000` without touching the ALB. No external routing, no latency overhead.

Ghost supports several event types—member added, member deleted, member edited, post published, post unpublished, and more. For this demo, select **Member added** and **Member edited**, then click **Save**.

### Test the Integration

Create a test member in Ghost admin:

1. Go to **Settings → Members**
2. Click **New member**
3. Enter an email address (e.g., `test@example.com`)
4. Click **Save**

![Test webhook by adding a member in Ghost admin](/media/images/2026/02/webhooks/ghost-webhook-test-trigger.png)

Ghost fires a POST to your webhook receiver with the member data. Check CloudWatch to see it arrive:


```bash
aws logs tail "/ecs/ghost-ecs-webhook" --since 2m --region us-west-2
```


You'll see output like:

```
==================================================
WEBHOOK RECEIVED
==================================================
Headers: {'host': '...', 'user-agent': 'Ghost/...', 'content-type': 'application/json', ...}
Body (JSON): {
  "member": {
    "current": {
      "id": "abc123def456",
      "uuid": "...",
      "email": "test@example.com",
      "name": null,
      "status": "free",
      "created_at": "2026-02-07T20:16:11.000Z",
      "updated_at": "2026-02-07T20:16:11.000Z",
      ...
    },
    "previous": {}
  }
}
==================================================
```

Every member event shows up in CloudWatch with full headers and body. From here you could extend `app.py` to write events to DynamoDB, trigger a Lambda for welcome emails, push to a CRM, or stream to Kinesis for real-time processing. The receiver is a starting point—what you do with the events depends on your use case.

## Validation

Confirm both containers are running and the ALB target is passing health checks.


```bash
TASK_ARN=$(aws ecs list-tasks \
  --cluster ghost-ecs-cluster \
  --service-name ghost-ecs-service \
  --region us-west-2 \
  --query 'taskArns[0]' \
  --output text)

aws ecs describe-tasks \
  --cluster ghost-ecs-cluster \
  --tasks $TASK_ARN \
  --region us-west-2 \
  --query 'tasks[0].containers[*].{Name:name,Status:lastStatus,Health:healthStatus}'
```


Expected output:

```json
[
  {
    "Name": "ghost",
    "Status": "RUNNING",
    "Health": "UNKNOWN"
  },
  {
    "Name": "webhook-receiver",
    "Status": "RUNNING",
    "Health": "UNKNOWN"
  }
]
```

Both containers should show `RUNNING`. `Health: UNKNOWN` is expected since no container-level health checks are defined.

Check ALB target health for Ghost:


```bash
aws elbv2 describe-target-health \
  --target-group-arn "$(terraform output -raw alb_target_group_arn)" \
  --region us-west-2 \
  --query 'TargetHealthDescriptions[*].{Target:Target.Id,Port:Target.Port,State:TargetHealth.State}'
```


Ghost should show `State: healthy`. The webhook receiver won't appear here—it's not registered with the ALB.

**Common issues:**

- **Webhook container not running**: Check logs with `aws logs tail "/ecs/ghost-ecs-webhook" --since 10m --region us-west-2`
- **No webhook events received**: Confirm the webhook URL in Ghost admin is `http://localhost:8000/webhook` and the integration is saved
- **Ghost can't reach webhook receiver**: Verify both containers are in the same task (they share the network namespace automatically)

## What This Design Gets You (and Where It Breaks Down)

The webhook receiver is invisible from the internet. It's not registered with the ALB and the security group blocks port 8000 from outside the task. Only Ghost can reach it, over `localhost`, with zero latency overhead. You didn't add any service discovery, ALB rules, or security group changes to make this work.

That simplicity has its own drawback. Ghost scales based on HTTP traffic. A webhook processor should scale based on event volume. Those are different signals, and a single task can't respond to both. If you update the webhook handler, you're redeploying Ghost too. And if the webhook receiver has a memory leak, it eats into Ghost's allocation.

For production, the path forward is:

1. Split Ghost and webhooks into separate ECS services with Service Connect for private communication
2. Put SQS between Ghost and the webhook processor so event delivery is decoupled from processing
3. Scale webhook workers independently based on queue depth
4. Add circuit breakers so webhook failures can't cascade into Ghost

A future post covers that split—separate tasks, Service Connect for inter-service routing, and independent autoscaling.

## Cost and Security Notes

**Cost:**

Adding the webhook container doesn't increase your Fargate bill—it shares the same task's CPU and memory allocation. The only new costs are ECR image storage and a small amount of CloudWatch Logs. The ALB, NAT gateway, and Aurora Serverless v2 continue billing from the original deployment. Check current pricing in the AWS documentation before deploying to shared accounts.

**Security:**

The webhook receiver can't be reached from outside the task. The security group blocks port 8000, and it's not registered with the ALB. Only Ghost can reach it, and only over `localhost`. Keep the ALB locked down—the default `0.0.0.0/0` ingress is fine for testing, but restrict it or add WAF rules for production. Store secrets in Secrets Manager. Use least-privilege IAM on the task execution role.

## Cleanup

Destroy all resources to stop billing:


```bash
terraform destroy -auto-approve
```


This tears down everything—ECS service, task definition, ALB, Aurora cluster, ECR repositories, and networking.

## Production Notes / Next Steps

The multi-container task gets you running fast, but production needs more separation. A future post will split Ghost and the webhook receiver into independent ECS services with Service Connect for private routing—giving you independent scaling, separate deployment cycles, and resource isolation.

External references:

- <a href="https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_definition_parameters.html#container_definitions" target="_blank" rel="noopener">ECS task definition parameters</a>
- <a href="https://docs.ghost.org/webhooks/" target="_blank" rel="noopener">Ghost webhooks documentation</a>
- <a href="https://fastapi.tiangolo.com/" target="_blank" rel="noopener">FastAPI framework</a>

## Conclusion

- Multi-container tasks let you run tightly coupled services in the same network namespace with zero discovery overhead
- The webhook receiver runs alongside Ghost without touching the ALB, security groups, or adding infrastructure cost
- Ghost sends member events to `localhost:8000`, and they show up in CloudWatch
- The coupling works for prototyping. Split into separate tasks when you need independent scaling or deployment cycles

You've gone from a single-container ECS task to a multi-service deployment without adding infrastructure complexity. A future post breaks the coupling: separate tasks, Service Connect for private routing, and autoscaling for each service independently.
