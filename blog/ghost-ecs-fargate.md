
So far in this Ghost series, you've run the stack locally with Docker Compose, deployed it on AWS with systemd, and then moved to Docker containers running directly on EC2—pulling from the public Docker registry with a simple `docker run` command. Each step was deliberate: local development showed the full stack, systemd showed native OS service management, and Docker on EC2 showed container operations at the infrastructure level.

Now you're ready to hand the container lifecycle to AWS. ECS Fargate removes the EC2 layer entirely. You don't manage instances, patch AMIs, or tune autoscaling groups. AWS schedules your Ghost container, monitors it, and restarts it when needed. You still own the networking, database, and load balancer setup—the infrastructure boundaries stay the same. The ALB remains in public subnets, Aurora stays private, and security groups enforce traffic boundaries between tiers.

The container runtime being managed doesn't make Ghost stateless. Ghost still writes to the filesystem. Your database connections still need proper security group rules. Content uploads still need persistent storage. Fargate abstracts the EC2 layer, but it doesn't solve state management or networking for you.

If you followed [Host Your Own Ghost CMS Locally: Multi-Service Stack with Docker Compose](./host-ghost-cms-locally-multi-service-stack-docker-compose.md), [Take Ghost CMS to Production on AWS: CloudFront, ALB, and Aurora Serverless](./ghost-production-aws-cloudfront-alb-aurora.md), [Ghost CMS on AWS with NAT Instances](./ghost-production-aws-nat-instances.md), and [Ghost CMS with Docker on EC2](./ghost-production-docker-containers-ec2.md), this is the next step.

<iframe width="776" height="437" src="https://www.youtube.com/embed/_sy8XUhLaUI" title="Ghost CMS on ECS Fargate" frameborder="0" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" allowfullscreen></iframe>

## What You'll Build

You'll deploy Ghost on ECS Fargate backed by Aurora Serverless v2. The container runs in private subnets and connects to the database over internal networking. An Application Load Balancer exposes the service to the internet. Ghost will use the ALB DNS name by default, or you can configure a custom domain. Security groups restrict traffic between tiers, and Secrets Manager holds the database password so it never appears in your task definition or Terraform outputs.

**Architecture:**

```
Client
  ↓
Application Load Balancer (public subnets)
  ↓
ECS Fargate service (private subnets)
  ↓
Aurora Serverless v2 (private subnets)
```

| Component | Purpose |
|----------|---------|
| VPC | Isolated networking across public and private subnets |
| ALB | Public entry point for Ghost |
| ECS Fargate | Run the Ghost container without managing EC2 |
| Aurora Serverless v2 | MySQL database for Ghost |
| Secrets Manager | Store DB password used by the task |

## Prerequisites

- AWS account with permissions for VPC, ECS, ECR, ELB, RDS, IAM, and Secrets Manager
- Region: `us-west-2`
- Terraform **v1.13.4+** and AWS provider **v6.20.0+**
- AWS CLI **v2**
- Docker Desktop **v4.49+** (only needed if you want to test the image locally)

⚠️ Caution: ECS Fargate and Aurora Serverless are billed per usage. Check current pricing in the AWS documentation before running this in a shared account.

## Why Fargate?

Fargate removes the EC2 layer. You don't patch AMIs, manage EC2 instance types, or worry about cluster capacity. AWS schedules your tasks on managed infrastructure and bills per vCPU-second and memory consumed. You can still configure service autoscaling to add or remove tasks based on CPU, memory, or custom metrics—but you're not sizing EC2 instances. You still control the VPC, subnets, security groups, and logs.

The trade-off is that Fargate tasks use ephemeral storage. Ghost writes uploads and themes to the filesystem by default. Without persistent storage, content is lost when tasks are replaced. This tutorial shows the Fargate basics without EFS—plan to add EFS mounts or an S3 storage adapter for production deployments.

## Step 1: Create the Terraform project

Start with a clean Terraform workspace. Configure the AWS provider and define variables for region, project name, Ghost URL, and database settings.

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


Create `terraform.tfvars`:


```terraform
# Optional: Set ghost_url if using a custom domain
# ghost_url = "https://blog.example.com"

# If not set, defaults to http://<alb-dns-name>
```


💡 Tip: The `ghost_url` defaults to the ALB DNS name with `http://`. If you're using a custom domain with CloudFront and ACM, set `ghost_url = "https://yourdomain.com"` in `terraform.tfvars`. The `admin_cidr` defaults to `0.0.0.0/0` for testing—restrict this to your IP range for production.

## Step 2: Provision networking, ALB, and Aurora

Provision a VPC with public and private subnets, an ALB, Aurora Serverless v2, and security groups that enforce traffic boundaries between tiers.

Create `network.tf`:


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
    security_groups = [aws_security_group.ecs.id]
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


This creates a two-AZ VPC with public and private subnets, an ALB, and Aurora Serverless v2. Security groups enforce boundaries: the ECS tasks accept traffic only from the ALB, and Aurora accepts connections only from ECS. The ALB accepts traffic from `admin_cidr`, which defaults to `0.0.0.0/0` for testing.

⚠️ Caution: A NAT gateway is created for outbound access from private subnets. It bills by the hour and per GB transferred. If you want to avoid NAT costs, use VPC endpoints for ECR and CloudWatch Logs. Assigning public IPs to tasks is another option but not recommended for production—it exposes tasks directly to the internet even with security groups in place.

## Step 3: Deploy ECS cluster and Ghost task

Create the ECS cluster and task definition. Configure the Ghost container to pull the database password from Secrets Manager and send logs to CloudWatch. Deploy the service in private subnets behind the ALB.

Create `ecs.tf`:


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
    subnets         = module.vpc.private_subnets
    security_groups = [aws_security_group.ecs.id]
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


The task definition references the database password from Secrets Manager using the `secrets` block. ECS fetches the value at runtime so your password never appears in Terraform state or outputs. Logs go to CloudWatch under `/ecs/ghost-ecs`.

The ECS service runs in private subnets and registers tasks with the ALB target group. Traffic flows from the ALB to the container on port 2368.

⚠️ Caution: This task definition does not mount persistent storage for `/var/lib/ghost/content`. Ghost uploads, themes, and custom files live on the task's ephemeral filesystem and will be lost when the task is replaced (deployments, scaling, failures). For production, mount an EFS volume so all tasks share the same content. This tutorial focuses on the ECS Fargate basics—persistent storage is a separate concern.

💡 Tip: The secret reference format `:password::` extracts a specific JSON key from Secrets Manager. If your secret is a flat string, omit the key name.

## Step 4: Configure outputs

Expose the ALB DNS name and database endpoint for validation and testing.

Create `outputs.tf`:


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


## Step 5: Apply the configuration

Run Terraform to provision the infrastructure.


```bash
aws sts get-caller-identity
terraform init
terraform fmt
terraform validate
terraform apply -auto-approve
```


✅ Result: Terraform prints the `alb_dns_name` and `ghost_url`. If you didn't provide a custom URL, Ghost will be configured with the ALB DNS name automatically.

## Validation

Check that ECS tasks are running:


```bash
aws ecs list-clusters --region us-west-2
aws ecs list-services --cluster ghost-ecs-cluster --region us-west-2
aws ecs describe-services --cluster ghost-ecs-cluster --services ghost-ecs-service --region us-west-2
```


Check target health:


```bash
aws elbv2 describe-target-health \
  --target-group-arn "$(terraform output -raw alb_target_group_arn 2>/dev/null || true)" \
  --region us-west-2
```


The target state should be `healthy`. If it shows `unhealthy`, check the task logs:


```bash
aws logs tail "/ecs/ghost-ecs" --since 10m --region us-west-2
```


**Common issues:**

- **Database connect timeout**: Confirm the DB security group allows port 3306 from the ECS task security group.
- **ALB 502 error**: Verify the task is listening on port 2368 and your `ghost_url` matches the ALB DNS name.

## Cost and Security Notes

**Cost:**

This stack creates an ALB, NAT gateway, and Aurora Serverless v2 cluster. Each bills while running, even if idle. Destroy resources when you're done and check current pricing in the AWS documentation.

**Security:**

- The ALB defaults to `0.0.0.0/0` for testing—restrict `admin_cidr` to your IP range for production or place CloudFront in front with WAF rules
- Use least-privilege IAM policies for task execution roles
- Store all secrets in Secrets Manager or SSM Parameter Store
- Never commit secrets to Git or embed them in task definitions

## Cleanup

Destroy all resources to avoid ongoing charges:


```bash
terraform destroy -auto-approve
```


⚠️ Caution: Aurora and NAT gateways continue to bill until destroyed.

## Production Notes / Next Steps

**TLS and caching:**

This setup uses HTTP-only on port 80. For production, add ACM certificates and CloudFront for HTTPS and global edge caching.

You can adapt the complete CloudFront and ACM setup from [Take Ghost CMS to Production on AWS: CloudFront, ALB, and Aurora Serverless](./ghost-production-aws-cloudfront-alb-aurora.md) to this ECS Fargate architecture. The setup is nearly identical—you're just swapping the EC2 Auto Scaling Group for ECS Fargate tasks.

**What to adapt:**

1. **Add HTTPS listener to the ALB** - Update `network.tf` to add port 443 to the ALB security group and create an HTTPS listener with an ACM certificate in your region (e.g., us-west-2)

2. **Create ACM certificates** - Use the ACM module from the CloudFront post to create two certificates:
   - One for CloudFront (must be in us-east-1)
   - One for the ALB (in your deployment region, e.g., us-west-2)

3. **Add CloudFront distribution** - Use the CloudFront module and cache policies from the CloudFront post. Point the origin to your ALB DNS name with `origin_protocol_policy = "https-only"`

4. **Configure Route53** - Add the DNS record to point your domain to CloudFront (handled automatically by the ACM module if you provide a Route53 zone)

5. **Update Ghost URL** - Change `ghost_url` in `terraform.tfvars` from `http://` to `https://yourdomain.com`

The modules in the CloudFront post (ACM, CloudFront, cache policies, origin request policies) work identically with ECS Fargate. The only difference is that your origin targets ECS tasks via the ALB instead of EC2 instances via the ALB. The traffic flow remains: CloudFront → ALB → ECS tasks → Aurora.

**CI/CD:**

Use GitHub Actions OIDC to deploy infrastructure changes without access keys. See [Stop Using Access Keys in GitHub Actions](./stop-using-access-keys-github-actions-aws.md).

**Cost optimization:**

Replace the NAT gateway with NAT instances to reduce egress costs. See [Ghost CMS on AWS with NAT Instances: Cut Egress Costs by 70%](./ghost-production-aws-nat-instances.md).

**Persistent storage:**

This tutorial does not implement persistent storage for Ghost uploads and themes. For production use, mount an EFS volume to `/var/lib/ghost/content` or configure Ghost's S3 storage adapter. Without persistent storage, uploads are lost on task replacement and multi-task deployments will have inconsistent content.

External references:

- <a href="https://docs.aws.amazon.com/AmazonECS/latest/developerguide/Welcome.html" target="_blank" rel="noopener">Amazon ECS documentation</a>
- <a href="https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2.html" target="_blank" rel="noopener">Aurora Serverless v2 documentation</a>

## Conclusion

- ECS Fargate removes the EC2 layer—no patching, no cluster sizing
- Aurora Serverless v2 scales the database without manual instance management
- Security groups enforce boundaries between ALB, ECS tasks, and Aurora
- Secrets Manager keeps credentials out of task definitions and Terraform state
- CloudWatch Logs centralizes container logs for troubleshooting

You've moved from Docker on EC2 to Fargate. AWS now handles the container runtime, but you still control the infrastructure. The series continues with persistent storage options, multi-service communication, EC2-backed ECS clusters, and autoscaling strategies.
