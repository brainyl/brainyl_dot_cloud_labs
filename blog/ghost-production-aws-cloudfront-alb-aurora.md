
If you followed [Host Your Own Ghost CMS Locally: Multi-Service Stack with Docker Compose](./host-ghost-cms-locally-multi-service-stack-docker-compose.md), you have a working Ghost blog running on your machine with MySQL, MailHog, and Caddy. That stack works for local development, but when you're ready to share your blog with the world, you need production infrastructure that scales, stays available, and handles traffic spikes without manual intervention.

Ghost's official documentation shows how to install Ghost on a single Ubuntu server with NGINX, MySQL, and Let's Encrypt. That approach leaves you managing SSL renewals, server patches, database backups, and handling downtime when that single server fails or needs updates.

AWS removes that operational overhead. CloudFront handles SSL via ACM certificates that auto-renew. The Application Load Balancer distributes traffic across multiple EC2 instances in different availability zones. Aurora Serverless v2 replaces a single MySQL instance with a managed database that scales capacity automatically based on load.

This post shows you how to deploy that production architecture using Terraform modules from the [Terraform Registry](https://registry.terraform.io/)—the same tools and patterns that run thousands of production workloads on AWS.

## What You'll Build

A production Ghost deployment using these community modules:

- **[terraform-aws-modules/vpc](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws)** - VPC with public/private subnets, NAT gateway
- **[terraform-aws-modules/security-group](https://registry.terraform.io/modules/terraform-aws-modules/security-group/aws)** - Security groups for ALB, EC2, Aurora
- **[terraform-aws-modules/alb](https://registry.terraform.io/modules/terraform-aws-modules/alb/aws)** - Application Load Balancer
- **[terraform-aws-modules/autoscaling](https://registry.terraform.io/modules/terraform-aws-modules/autoscaling/aws)** - Auto Scaling Group
- **[terraform-aws-modules/rds-aurora](https://registry.terraform.io/modules/terraform-aws-modules/rds-aurora/aws)** - Aurora Serverless v2
- **[terraform-aws-modules/acm](https://registry.terraform.io/modules/terraform-aws-modules/acm/aws)** - ACM SSL certificate
- **[terraform-aws-modules/cloudfront](https://registry.terraform.io/modules/terraform-aws-modules/cloudfront/aws)** - CloudFront CDN

**Architecture:**

![Ghost CMS production architecture on AWS showing traffic flow from users through CloudFront in us-east-1 to Application Load Balancer and EC2 instances in Auto Scaling Group across multiple availability zones in us-west-2, connected to Aurora Serverless database](/media/images/2025/12/01/ghost-production-aws-architecture.png)

Traffic flows from users through CloudFront (global CDN with TLS termination) to the Application Load Balancer in us-west-2, which distributes requests across EC2 instances running Ghost in an Auto Scaling Group. All instances connect to the same Aurora Serverless v2 database cluster.

| Component | Module | Purpose |
|-----------|--------|---------|
| VPC | terraform-aws-modules/vpc | Network isolation, 2 AZs |
| ALB | terraform-aws-modules/alb | Load balancing, health checks |
| ASG | terraform-aws-modules/autoscaling | Ghost EC2 instances, auto-healing |
| Aurora | terraform-aws-modules/rds-aurora | MySQL database, scales to 0.5 ACU |
| CloudFront | terraform-aws-modules/cloudfront | Global CDN, SSL termination |
| ACM | terraform-aws-modules/acm | Free SSL certificate |

## Prerequisites

- **AWS account** with appropriate permissions
- **Terraform** ≥ v1.13.4
- **AWS CLI** v2 configured
- **Domain name** with DNS access
- **Region**: `us-west-2` (adjust as needed)

**Cost**: ~$125-150/month (24/7 operation). Destroy resources after testing.

---

## How CloudFront and ACM Replace Caddy

In local development (see [Host Your Own Ghost CMS Locally: Multi-Service Stack with Docker Compose](./host-ghost-cms-locally-multi-service-stack-docker-compose.md)), you use **Caddy** to terminate TLS with self-signed certificates. Caddy handles `https://localhost` and reverse-proxies requests to Ghost.

In production on AWS:

- **CloudFront** replaces Caddy's reverse proxy and TLS termination
- **ACM (AWS Certificate Manager)** replaces Caddy's certificate generation (or Let's Encrypt on a single server)
- **ALB** handles load balancing across multiple instances

Here's the comparison:

| Function | Local (Caddy) | Production (AWS) |
|----------|---------------|------------------|
| **TLS Termination** | Caddy with self-signed cert | CloudFront with ACM certificate |
| **Certificate Renewal** | Manual (self-signed) or Caddy auto-renew | ACM auto-renews |
| **Reverse Proxy** | Caddy → Ghost container | CloudFront → ALB → EC2 (Ghost) |
| **Load Balancing** | Single instance | ALB distributes to multiple EC2 instances |
| **Edge Caching** | None | CloudFront POPs worldwide |

**Why CloudFront?**

- **Global edge caching**: Static assets (CSS, JS, images) are cached at CloudFront edge locations worldwide, reducing latency and load on your origin.
- **Free SSL**: ACM certificates are free and auto-renew.
- **DDoS protection**: CloudFront includes AWS Shield Standard at no extra cost.

**Why ALB?**

- **Horizontal scaling**: ALB distributes traffic across multiple EC2 instances in different availability zones.
- **Health checks**: ALB removes unhealthy instances from rotation automatically.
- **SSL offloading**: ALB can also terminate SSL (between CloudFront and ALB we use HTTPS, but you could use HTTP between ALB and EC2 instances in a VPC).

---

## How the ALB Scales Across Multiple EC2 Instances

The **Auto Scaling Group (ASG)** launches EC2 instances running Ghost. The **ALB** distributes incoming HTTP requests across all healthy instances.

When you configure the ASG:

- **Desired capacity**: Number of instances to run normally (we'll use 2 for high availability)
- **Min capacity**: Minimum instances (2)
- **Max capacity**: Maximum instances (4) for scaling during traffic spikes

The ALB performs **health checks** by sending HTTP requests to `/` (Ghost's homepage). If an instance fails health checks, the ALB stops routing traffic to it, and the ASG replaces it.

Each EC2 instance runs the same **userdata script** at boot:

1. Install Node.js 22
2. Install MySQL client
3. Install Ghost-CLI
4. Install Ghost in `/var/www/ghost`
5. Configure Ghost with the Aurora database endpoint (fetched from AWS Systems Manager Parameter Store)
6. Start Ghost with systemd

Because all instances connect to the same Aurora database, they share content. Ghost handles this architecture well as long as you configure it correctly (we'll set the database host dynamically via SSM parameters).

---

## Architecture Decision: Why Aurora Serverless v2?

**Aurora Serverless v2** is a MySQL-compatible database that automatically scales capacity (ACUs) based on load.

**Benefits:**

- **Scales to zero** – Can scale down to 0 ACU when completely idle (only storage costs apply)
- **Automatic backups** to S3 with point-in-time recovery
- **Multi-AZ replication** for high availability (optional, adds cost)
- **No manual MySQL patches** – AWS handles updates automatically
- **Better than RDS for variable load** – scales up during traffic spikes, scales down to zero when idle

**Trade-offs:**

- **Cold start latency**: Scaling from 0 ACU takes ~30 seconds when traffic arrives
- **Storage costs even at 0 ACU** – You still pay for storage (~$0.10/GB/month) when scaled to zero
- **More expensive than t3.micro under constant load** – A `db.t3.micro` RDS instance costs ~$15/month but doesn't auto-scale
- **Variable cost** – Billing is per-second for ACU usage, so costs vary with load

**When to use Aurora Serverless v2:**

- Production blogs with **variable traffic** (traffic spikes during post releases, idle overnight)
- You need **multi-AZ** availability without managing replicas
- You want to minimize costs during idle periods by scaling to zero

**When to skip it:**

- **Predictable, constant load** – Standard RDS instances with reserved capacity are cheaper
- **Cannot tolerate cold starts** – The 30-second wake time from 0 ACU isn't acceptable
- **Testing/development** – Stop/start standard RDS instances to save money without cold starts

💡 **Tip:** This setup configures Aurora to scale from 0 to 1 ACU. For most Ghost blogs, that's enough. If you expect sustained high traffic, increase `max_capacity` to 2 or 4 ACUs.

---

## Project Structure

```
ghost-production-aws-cloudfront-alb-aurora/
├── main.tf                   # All module declarations
├── variables.tf              # Input variables
├── outputs.tf                # Outputs (ALB DNS, CloudFront domain)
├── terraform.tf              # Provider configuration
├── userdata.sh               # EC2 bootstrap script
└── terraform.tfvars          # Your values (not committed)
```

Everything in one `main.tf` file. Modules abstract the complexity.

---

## Step 1: Provider Configuration

Create `terraform.tf`:



```terraform
terraform {
  required_version = ">= 1.13.4"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.20.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# CloudFront and ACM certificates for CloudFront must be created in us-east-1
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}
```

---

## Step 2: Variables

Create `variables.tf`:



```terraform
variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "us-west-2"
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "ghost-blog"
}

variable "domain_name" {
  description = "Domain name for Ghost blog (e.g. blog.example.com)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of availability zones"
  type        = list(string)
  default     = ["us-west-2a", "us-west-2b"]
}

variable "ec2_instance_type" {
  description = "EC2 instance type for Ghost servers"
  type        = string
  default     = "t3.small"
}

variable "asg_desired_capacity" {
  description = "Desired number of EC2 instances"
  type        = number
  default     = 2
}

variable "asg_min_size" {
  description = "Minimum number of EC2 instances"
  type        = number
  default     = 2
}

variable "asg_max_size" {
  description = "Maximum number of EC2 instances"
  type        = number
  default     = 4
}

variable "db_master_username" {
  description = "Master username for Aurora"
  type        = string
  default     = "ghostadmin"
}

variable "db_master_password" {
  description = "Master password for Aurora (not used - RDS managed password is used instead)"
  type        = string
  sensitive   = true
  default     = null
}

variable "db_name" {
  description = "Database name for Ghost"
  type        = string
  default     = "ghost_production"
}

variable "acm_certificate_arn" {
  description = "ARN of an existing validated ACM certificate in us-east-1. If not provided, a new certificate will be created (must be validated before CloudFront can use it)"
  type        = string
  default     = null
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID. If not provided, Terraform will try to find it automatically based on domain_name"
  type        = string
  default     = null
}
```

Create `terraform.tfvars`:



```terraform
# Example terraform.tfvars file
# Copy this to terraform.tfvars and update with your values

domain_name     = "blog.example.com"

# IMPORTANT: You need a Route53 hosted zone for your domain
# Terraform will:
# 1. Automatically create ACM certificate validation DNS records
# 2. Automatically create an A record (alias) pointing to CloudFront
# 
# If your hosted zone name matches domain_name exactly, Terraform finds it automatically.
# If using a subdomain (e.g., blog.example.com) with a parent zone (example.com),
# provide the parent zone ID explicitly:
# route53_zone_id = "XXXXXXXXXXXXX"  # Zone ID for example.com

# Note: db_master_password is not needed - RDS will generate a managed password
# and store it in AWS Secrets Manager automatically

# Optional: Override defaults
# project_name     = "my-ghost-blog"
# aws_region       = "us-west-2"
# ec2_instance_type = "t3.small"
```

---

## Step 3: Main Infrastructure (All Modules)

Create `main.tf` - this is where all the magic happens:



```terraform
################################################################################
# VPC Module
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "${var.project_name}-vpc"
  cidr = var.vpc_cidr

  azs              = var.availability_zones
  public_subnets   = [for k, v in var.availability_zones : cidrsubnet(var.vpc_cidr, 4, k)]
  private_subnets  = [for k, v in var.availability_zones : cidrsubnet(var.vpc_cidr, 4, k + length(var.availability_zones))]
  database_subnets = [for k, v in var.availability_zones : cidrsubnet(var.vpc_cidr, 4, k + (2 * length(var.availability_zones)))]

  enable_nat_gateway = true
  single_nat_gateway = true # Cost optimization: use one NAT GW (see below)
  enable_dns_hostnames = true
  enable_dns_support   = true

  create_database_subnet_group = true

  tags = {
    Project = var.project_name
  }
}
```

### Infrastructure Decision: Single NAT Gateway

This setup uses `single_nat_gateway = true`, which creates **one NAT Gateway** for both availability zones.

**Why one NAT Gateway:**

- **Cost savings**: NAT Gateways cost ~$32/month **each** plus data transfer fees
- **Acceptable for dev/test**: Reduces costs during testing and development
- **Simple setup**: One NAT GW means one bill, easier cost tracking

**The risk:**

- The NAT Gateway lives in **one AZ** (e.g., us-west-2a)
- If that specific AZ fails, **private subnets in BOTH AZs lose internet access**
- Your EC2 instances can't pull updates, connect to external APIs, or reach Aurora in database subnets

**Why you might want two:**

- **True high availability**: Each AZ gets its own NAT Gateway—if one AZ fails, the other continues working independently
- **Production-grade resilience**: No single point of failure for outbound internet traffic
- **Compliance requirements**: Some workloads require multi-AZ NAT for redundancy

**To enable multi-AZ NAT:**

```terraform
single_nat_gateway = false  # Creates one NAT GW per AZ
```

**Cost impact**: Changes from ~$32/month to ~$64/month for two NAT Gateways.

For a production blog where availability matters more than cost, set `single_nat_gateway = false`.

💡 **Tip:** In a future post, we'll show how to replace NAT Gateways with NAT instances to eliminate this recurring cost entirely—useful for dev/test environments or cost-sensitive production workloads.

Continue with security groups:

```terraform
################################################################################
# Security Groups
################################################################################

module "alb_security_group" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = "${var.project_name}-alb-sg"
  description = "Security group for ALB"
  vpc_id      = module.vpc.vpc_id

  ingress_with_cidr_blocks = [
    {
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = "0.0.0.0/0"
      description = "Allow HTTP from anywhere"
    },
    {
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = "0.0.0.0/0"
      description = "Allow HTTPS from anywhere"
    }
  ]

  egress_with_cidr_blocks = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = "0.0.0.0/0"
      description = "Allow all outbound"
    }
  ]

  tags = {
    Project = var.project_name
  }
}

module "ec2_security_group" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = "${var.project_name}-ec2-sg"
  description = "Security group for Ghost EC2 instances"
  vpc_id      = module.vpc.vpc_id

  computed_ingress_with_source_security_group_id = [
    {
      from_port                = 2368
      to_port                  = 2368
      protocol                 = "tcp"
      source_security_group_id = module.alb_security_group.security_group_id
      description              = "Allow Ghost traffic from ALB"
    }
  ]

  number_of_computed_ingress_with_source_security_group_id = 1

  egress_with_cidr_blocks = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = "0.0.0.0/0"
      description = "Allow all outbound"
    }
  ]

  tags = {
    Project = var.project_name
  }
}

module "aurora_security_group" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = "${var.project_name}-aurora-sg"
  description = "Security group for Aurora"
  vpc_id      = module.vpc.vpc_id

  computed_ingress_with_source_security_group_id = [
    {
      from_port                = 3306
      to_port                  = 3306
      protocol                 = "tcp"
      source_security_group_id = module.ec2_security_group.security_group_id
      description              = "Allow MySQL from EC2"
    }
  ]

  number_of_computed_ingress_with_source_security_group_id = 1

  egress_with_cidr_blocks = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = "0.0.0.0/0"
      description = "Allow all outbound"
    }
  ]

  tags = {
    Project = var.project_name
  }
}

################################################################################
# Aurora Serverless v2
################################################################################

module "aurora" {
  source  = "terraform-aws-modules/rds-aurora/aws"
  version = "~> 9.0"

  name           = "${var.project_name}-cluster"
  engine         = "aurora-mysql"
  engine_mode    = "provisioned"
  engine_version = "8.0.mysql_aurora.3.10.0"

  master_username              = var.db_master_username
  manage_master_user_password  = true
  database_name                = var.db_name

  vpc_id                 = module.vpc.vpc_id
  db_subnet_group_name   = module.vpc.database_subnet_group_name
  create_db_subnet_group = false

  vpc_security_group_ids = [module.aurora_security_group.security_group_id]

  skip_final_snapshot = true

  serverlessv2_scaling_configuration = {
    min_capacity = 0.0
    max_capacity = 1
  }

  instance_class = "db.serverless"
  instances = {
    one = {}
  }

  tags = {
    Project = var.project_name
  }
}

################################################################################
# SSM Parameters for Database Connection
################################################################################

resource "aws_ssm_parameter" "db_host" {
  name  = "/${var.project_name}/db-host"
  type  = "String"
  value = module.aurora.cluster_endpoint

  tags = {
    Project = var.project_name
  }
}

resource "aws_ssm_parameter" "db_name" {
  name  = "/${var.project_name}/db-name"
  type  = "String"
  value = var.db_name

  tags = {
    Project = var.project_name
  }
}

resource "aws_ssm_parameter" "db_username" {
  name  = "/${var.project_name}/db-username"
  type  = "String"
  value = var.db_master_username

  tags = {
    Project = var.project_name
  }
}

resource "aws_ssm_parameter" "db_password" {
  name  = "/${var.project_name}/db-password"
  type  = "String"
  value = module.aurora.cluster_master_user_secret[0].secret_arn

  tags = {
    Project = var.project_name
  }
}

################################################################################
# IAM Role for EC2 Instances
################################################################################

resource "aws_iam_role" "ec2_role" {
  name = "${var.project_name}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Project = var.project_name
  }
}

resource "aws_iam_role_policy" "ec2_ssm_policy" {
  name = "${var.project_name}-ec2-ssm-policy"
  role = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/${var.project_name}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:*:secret:rds!cluster-*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_ssm_managed" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

################################################################################
# Application Load Balancer
################################################################################

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 10.0"

  name = "${var.project_name}-alb"

  load_balancer_type = "application"
  vpc_id             = module.vpc.vpc_id
  subnets            = module.vpc.public_subnets
  security_groups    = [module.alb_security_group.security_group_id]

  enable_deletion_protection = false

  listeners = {
    http = {
      port     = 80
      protocol = "HTTP"

      redirect = {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
    https = {
      port            = 443
      protocol        = "HTTPS"
      certificate_arn = local.acm_certificate_arn_alb

      forward = {
        target_group_key = "ghost"
      }
    }
  }

  target_groups = {
    ghost = {
      name                 = "${var.project_name}-tg"
      protocol             = "HTTP"
      port                 = 2368
      target_type          = "instance"
      deregistration_delay = 10
      create_attachment    = false # ASG handles attachments via traffic_source_attachments

      health_check = {
        enabled             = true
        healthy_threshold   = 2
        unhealthy_threshold = 3
        timeout             = 10
        interval            = 30
        path                = "/"
        matcher             = "200,301,302"
      }
    }
  }

  tags = {
    Project = var.project_name
  }
}

################################################################################
# Auto Scaling Group
################################################################################

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

module "asg" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "~> 9.0"

  name = "${var.project_name}-asg"

  min_size         = var.asg_min_size
  max_size         = var.asg_max_size
  desired_capacity = var.asg_desired_capacity

  vpc_zone_identifier = module.vpc.private_subnets
  traffic_source_attachments = {
    ghost = {
      traffic_source_identifier = module.alb.target_groups["ghost"].arn
      traffic_source_type       = "elbv2"
    }
  }
  health_check_type   = "ELB"
  health_check_grace_period = 300

  image_id      = data.aws_ami.ubuntu.id
  instance_type = var.ec2_instance_type

  iam_instance_profile_arn = aws_iam_instance_profile.ec2_profile.arn
  security_groups          = [module.ec2_security_group.security_group_id]

  user_data = base64encode(templatefile("${path.module}/userdata.sh", {
    project_name = var.project_name
    aws_region   = var.aws_region
    domain_name  = var.domain_name
  }))

  create_launch_template = true
  launch_template_name   = "${var.project_name}-lt"

  tags = {
    Project = var.project_name
  }
}

################################################################################
# Route53 Hosted Zone Lookup
################################################################################

# Try to find Route53 hosted zone for the domain (exact match)
# If you have a parent domain zone (e.g., brainyl.cloud) for a subdomain (lab.brainyl.cloud),
# provide route53_zone_id explicitly
data "aws_route53_zone" "main" {
  count        = var.route53_zone_id == null ? 1 : 0
  name         = var.domain_name
  private_zone = false
}

locals {
  route53_zone_id = coalesce(
    var.route53_zone_id,
    try(data.aws_route53_zone.main[0].zone_id, null)
  )
  has_route53_zone = local.route53_zone_id != null
}

################################################################################
# ACM Certificates
################################################################################

# ACM Certificate for CloudFront (must be in us-east-1)
module "acm_cloudfront" {
  source  = "terraform-aws-modules/acm/aws"
  version = "~> 5.0"

  providers = {
    aws = aws.us_east_1
  }

  domain_name = var.domain_name
  zone_id     = local.route53_zone_id

  validation_method      = "DNS"
  create_route53_records = local.has_route53_zone # Automatically create DNS records if Route53 zone found
  wait_for_validation    = local.has_route53_zone # Wait for validation if Route53 zone found

  tags = {
    Project = var.project_name
    Purpose = "CloudFront"
  }
}

# ACM Certificate for ALB (must be in us-west-2)
module "acm_alb" {
  source  = "terraform-aws-modules/acm/aws"
  version = "~> 5.0"

  domain_name = var.domain_name
  zone_id     = local.route53_zone_id

  validation_method      = "DNS"
  create_route53_records = local.has_route53_zone # Automatically create DNS records if Route53 zone found
  wait_for_validation    = local.has_route53_zone # Wait for validation if Route53 zone found

  tags = {
    Project = var.project_name
    Purpose = "ALB"
  }
}

# Use provided certificate ARN or the one created above
# IMPORTANT: Certificate must be VALIDATED before CloudFront can use it
locals {
  acm_certificate_arn_cloudfront = var.acm_certificate_arn != null ? var.acm_certificate_arn : module.acm_cloudfront.acm_certificate_arn
  acm_certificate_arn_alb        = module.acm_alb.acm_certificate_arn
}
```

### Why Two Certificates?

This setup creates **two separate ACM certificates** for the same domain name:

1. **CloudFront certificate** (in `us-east-1`) - CloudFront is a global service, but AWS requires CloudFront certificates to be created in the `us-east-1` region regardless of where your other resources live.

2. **ALB certificate** (in `us-west-2`) - The ALB needs a certificate in the same region where it's deployed. CloudFront connects to the ALB over HTTPS, so both need valid certificates for end-to-end encryption.

**Why not share one certificate?**

CloudFront can only use certificates created in `us-east-1`. Your ALB in `us-west-2` cannot use a certificate from `us-east-1` because ACM certificates are region-specific. Even though both certificates are for the same domain, they must be provisioned in their respective regions.

**Cost:** ACM certificates are free. There's no extra cost for having two certificates for the same domain.

**Security benefit:** This gives you end-to-end encryption:

- User → CloudFront (HTTPS with CloudFront certificate)
- CloudFront → ALB (HTTPS with ALB certificate)
- ALB → EC2 (HTTP, inside VPC)

Continue with the rest of the infrastructure:

```terraform

################################################################################
# CloudFront Cache Policies
################################################################################

# Custom cache policy for static assets with long TTL (1 year)
resource "aws_cloudfront_cache_policy" "static_assets_cache" {
  name    = "${var.project_name}-static-assets-cache-policy"
  comment = "Cache policy for static assets with 1 year TTL"

  min_ttl     = 86400      # 1 day minimum
  default_ttl = 31536000   # 1 year default
  max_ttl     = 31536000   # 1 year maximum

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }

    headers_config {
      header_behavior = "none"
    }

    query_strings_config {
      query_string_behavior = "none"
    }

    enable_accept_encoding_brotli = true
    enable_accept_encoding_gzip   = true
  }
}

################################################################################
# CloudFront Origin Request Policies
################################################################################

# Policy for dynamic content (Ghost admin) - forwards all headers/cookies
resource "aws_cloudfront_origin_request_policy" "alb_origin_policy" {
  name    = "${var.project_name}-alb-origin-request-policy"
  comment = "Origin request policy for ALB (Ghost) origin - forwards all viewer headers and cookies"

  cookies_config {
    cookie_behavior = "all"
  }

  headers_config {
    header_behavior = "allViewer"
  }

  query_strings_config {
    query_string_behavior = "all"
  }
}

# Policy for static assets - only forwards Host header
resource "aws_cloudfront_origin_request_policy" "static_assets_policy" {
  name    = "${var.project_name}-static-assets-origin-request-policy"
  comment = "Origin request policy for static assets - forwards only Host header"

  cookies_config {
    cookie_behavior = "none"
  }

  headers_config {
    header_behavior = "whitelist"
    headers {
      items = ["Host"]
    }
  }

  query_strings_config {
    query_string_behavior = "none"
  }
}

################################################################################
# CloudFront Distribution
################################################################################

module "cloudfront" {
  source  = "terraform-aws-modules/cloudfront/aws"
  version = "~> 3.0"

  aliases = [var.domain_name]

  comment             = "Ghost blog distribution"
  enabled             = true
  is_ipv6_enabled     = true
  price_class         = "PriceClass_100"
  retain_on_delete    = false
  wait_for_deployment = false

  origin = {
    alb = {
      domain_name = module.alb.dns_name
      custom_origin_config = {
        http_port              = 80
        https_port             = 443
        origin_protocol_policy = "https-only"
        origin_ssl_protocols   = ["TLSv1.2"]
      }
    }
  }

  default_cache_behavior = {
    target_origin_id       = "alb"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods  = ["GET", "HEAD"]
    compress        = true

    use_forwarded_values          = false
    cache_policy_name             = "Managed-CachingDisabled"
    origin_request_policy_id      = aws_cloudfront_origin_request_policy.alb_origin_policy.id
  }

  ordered_cache_behavior = [
    {
      path_pattern           = "/assets/*"
      target_origin_id       = "alb"
      viewer_protocol_policy = "redirect-to-https"

      allowed_methods = ["GET", "HEAD", "OPTIONS"]
      cached_methods  = ["GET", "HEAD"]
      compress        = true

      use_forwarded_values        = false
      cache_policy_id             = aws_cloudfront_cache_policy.static_assets_cache.id
      origin_request_policy_id    = aws_cloudfront_origin_request_policy.static_assets_policy.id
    },
    {
      path_pattern           = "/content/images/*"
      target_origin_id       = "alb"
      viewer_protocol_policy = "redirect-to-https"

      allowed_methods = ["GET", "HEAD", "OPTIONS"]
      cached_methods  = ["GET", "HEAD"]
      compress        = true

      use_forwarded_values        = false
      cache_policy_id             = aws_cloudfront_cache_policy.static_assets_cache.id
      origin_request_policy_id    = aws_cloudfront_origin_request_policy.static_assets_policy.id
    },
    {
      path_pattern           = "/media/*"
      target_origin_id       = "alb"
      viewer_protocol_policy = "redirect-to-https"

      allowed_methods = ["GET", "HEAD", "OPTIONS"]
      cached_methods  = ["GET", "HEAD"]
      compress        = true

      use_forwarded_values        = false
      cache_policy_id             = aws_cloudfront_cache_policy.static_assets_cache.id
      origin_request_policy_id    = aws_cloudfront_origin_request_policy.static_assets_policy.id
    },
    {
      path_pattern           = "/ghost/*"
      target_origin_id       = "alb"
      viewer_protocol_policy = "redirect-to-https"

      allowed_methods = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
      cached_methods  = ["GET", "HEAD"]

      use_forwarded_values          = false
      cache_policy_name             = "Managed-CachingDisabled"
      origin_request_policy_id      = aws_cloudfront_origin_request_policy.alb_origin_policy.id
    },
    {
      path_pattern           = "/ghost/api/*"
      target_origin_id       = "alb"
      viewer_protocol_policy = "redirect-to-https"

      allowed_methods = ["GET", "HEAD", "OPTIONS"]
      cached_methods  = ["GET", "HEAD"]

      use_forwarded_values          = false
      cache_policy_name             = "Managed-CachingDisabled"
      origin_request_policy_id      = aws_cloudfront_origin_request_policy.alb_origin_policy.id
    }
  ]

  viewer_certificate = {
    acm_certificate_arn      = local.acm_certificate_arn_cloudfront
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = {
    Project = var.project_name
  }
}

################################################################################
# Route53 Record for CloudFront
################################################################################

resource "aws_route53_record" "cloudfront" {
  count   = local.has_route53_zone ? 1 : 0
  zone_id = local.route53_zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = module.cloudfront.cloudfront_distribution_domain_name
    zone_id                = module.cloudfront.cloudfront_distribution_hosted_zone_id
    evaluate_target_health = false
  }
}
```

**What this creates:**

- VPC with public/private/database subnets across 2 AZs
- Security groups: CloudFront → ALB → EC2 → Aurora (computed references handled automatically)
- Aurora Serverless v2 cluster with 0.0-1 ACU scaling
- ALB with target group, health checks, and HTTP listener
- Auto Scaling Group launching Ghost EC2 instances
- ACM certificate with DNS validation
- CloudFront distribution with custom cache rules for Ghost admin paths

---

## Step 4: EC2 Userdata Script

Create `userdata.sh` (same as before):



```bash
#!/bin/bash
set -e

# Variables (will be replaced by Terraform templatefile)
PROJECT_NAME="${project_name}"
AWS_REGION="${aws_region}"
DOMAIN_NAME="${domain_name}"

# Update system packages
apt-get update
apt-get upgrade -y

# Install AWS CLI v2
apt-get install -y unzip curl
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/awscliv2.zip /tmp/aws

# Install jq for JSON parsing
apt-get install -y jq

# Fetch database connection details from SSM Parameter Store
DB_HOST=$(aws ssm get-parameter --name "/$PROJECT_NAME/db-host" --region $AWS_REGION --query 'Parameter.Value' --output text)
DB_NAME=$(aws ssm get-parameter --name "/$PROJECT_NAME/db-name" --region $AWS_REGION --query 'Parameter.Value' --output text)
DB_USER=$(aws ssm get-parameter --name "/$PROJECT_NAME/db-username" --region $AWS_REGION --query 'Parameter.Value' --output text)

# Fetch password from Secrets Manager (RDS managed password)
SECRET_ARN=$(aws ssm get-parameter --name "/$PROJECT_NAME/db-password" --region $AWS_REGION --query 'Parameter.Value' --output text)
if [[ $SECRET_ARN == arn:aws:secretsmanager:* ]]; then
  echo "Fetching password from Secrets Manager (RDS managed password)"
  echo "Secret ARN: $SECRET_ARN"
  DB_PASS=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --region $AWS_REGION --query 'SecretString' --output text | jq -r '.password')
  echo "Successfully retrieved password from Secrets Manager"
else
  echo "Using password directly from SSM Parameter Store"
  DB_PASS="$SECRET_ARN"
fi

# Install Node.js 22
apt-get install -y ca-certificates curl gnupg
mkdir -p /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
NODE_MAJOR=22
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list
apt-get update
apt-get install nodejs -y

# Install MySQL client
apt-get install -y mysql-client

# Install Ghost-CLI
npm install ghost-cli@latest -g

# Create Ghost directory
mkdir -p /var/www/ghost
chown ubuntu:ubuntu /var/www/ghost
chmod 775 /var/www/ghost

# Install Ghost as ubuntu user
# Pass variables as environment variables to the sudo command
sudo -u ubuntu env DOMAIN_NAME="$DOMAIN_NAME" DB_HOST="$DB_HOST" DB_NAME="$DB_NAME" DB_USER="$DB_USER" DB_PASS="$DB_PASS" NODE_ENV="production" bash <<'EOF'
set -e

cd /var/www/ghost

# Set URL and environment variables for Ghost-CLI (must be set before any ghost commands)
export NODE_ENV="production"

# Use ghost install with database flags for non-interactive setup
# This properly initializes the instance and creates systemd service with correct name
echo "Installing Ghost with non-interactive setup..."
ghost install \
  --url "https://$DOMAIN_NAME" \
  --db mysql \
  --dbhost "$DB_HOST" \
  --dbuser "$DB_USER" \
  --dbpass "$DB_PASS" \
  --dbname "$DB_NAME" \
  --no-prompt \
  --no-stack \
  --no-setup-nginx \
  --no-setup-ssl \
  --no-setup-mysql \
  --process systemd \
  --no-start

# Verify the config file was created
if [ ! -f config.production.json ]; then
  echo "ERROR: config.production.json was not created by ghost install"
  exit 1
fi

# Update config file to ensure correct database credentials
# Ghost-CLI might have created a 'ghostadmin' user, but we need to use the provided credentials
echo "Updating config with correct database credentials..."
cat > config.production.json <<CONFIG
{
  "url": "https://$DOMAIN_NAME",
  "server": {
    "port": 2368,
    "host": "0.0.0.0"
  },
  "database": {
    "client": "mysql",
    "connection": {
      "host": "$DB_HOST",
      "user": "$DB_USER",
      "password": "$DB_PASS",
      "database": "$DB_NAME",
      "charset": "utf8mb4"
    }
  },
  "mail": {
    "transport": "Direct"
  },
  "logging": {
    "transports": ["stdout"]
  },
  "process": "systemd",
  "paths": {
    "contentPath": "/var/www/ghost/content"
  }
}
CONFIG

# Debug: Show what was created
echo "=== Ghost installation complete ==="
echo "Config file contents:"
cat config.production.json
echo "================================="

# Test database connectivity with the provided credentials
echo "Testing database connectivity..."
mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -e "SELECT 1;" 2>&1 || {
  echo "ERROR: Cannot connect to database with provided credentials"
  echo "Host: $DB_HOST"
  echo "User: $DB_USER"
  echo "Database: $DB_NAME"
  exit 1
}
echo "Database connectivity test passed!"

# Verify systemd service was created with correct name
DOMAIN_ONLY=$(echo "$DOMAIN_NAME" | sed 's|https\?://||' | sed 's|/.*||')
EXPECTED_SERVICE="ghost_$(echo "$DOMAIN_ONLY" | tr '.' '-')"
echo "Expected service name: $${EXPECTED_SERVICE}"

if [ -f "/lib/systemd/system/$${EXPECTED_SERVICE}.service" ]; then
  echo "SUCCESS: Systemd service $${EXPECTED_SERVICE}.service was created"
else
  echo "WARNING: Expected systemd service $${EXPECTED_SERVICE}.service not found"
  echo "Checking for any ghost systemd services:"
  ls -la /lib/systemd/system/ghost_* 2>/dev/null || echo "No ghost services found"
fi

# Set up NGINX (skip SSL since we're using ALB with ACM)
echo "Setting up NGINX..."
ghost setup nginx --no-prompt

# Start Ghost
echo "Starting Ghost..."
ghost start
EOF

echo "Ghost installation complete!"
```

---

## Step 5: Outputs

Create `outputs.tf`:



```terraform
output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "alb_dns_name" {
  description = "ALB DNS name"
  value       = module.alb.dns_name
}

output "aurora_endpoint" {
  description = "Aurora cluster endpoint"
  value       = module.aurora.cluster_endpoint
}

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain name"
  value       = module.cloudfront.cloudfront_distribution_domain_name
}

output "cloudfront_id" {
  description = "CloudFront distribution ID"
  value       = module.cloudfront.cloudfront_distribution_id
}

output "acm_certificate_arn_cloudfront" {
  description = "ACM certificate ARN for CloudFront (us-east-1)"
  value       = module.acm_cloudfront.acm_certificate_arn
}

output "acm_certificate_arn_alb" {
  description = "ACM certificate ARN for ALB (us-west-2)"
  value       = module.acm_alb.acm_certificate_arn
}

output "acm_certificate_validation_domains" {
  description = "ACM certificate validation DNS records. Create these DNS records to validate the certificate."
  value       = module.acm_cloudfront.validation_domains
}

output "acm_certificate_status_cloudfront" {
  description = "ACM certificate status for CloudFront"
  value       = module.acm_cloudfront.acm_certificate_status
}

output "acm_certificate_status_alb" {
  description = "ACM certificate status for ALB"
  value       = module.acm_alb.acm_certificate_status
}

output "db_master_user_secret_arn" {
  description = "ARN of the Secrets Manager secret containing the database master password"
  value       = module.aurora.cluster_master_user_secret[0].secret_arn
}

output "db_master_username" {
  description = "Database master username"
  value       = var.db_master_username
}

output "db_name" {
  description = "Database name"
  value       = var.db_name
}

output "domain_name" {
  description = "Domain name pointing to CloudFront"
  value       = var.domain_name
}

output "route53_record_fqdn" {
  description = "Route53 record FQDN (if Route53 zone was provided)"
  value       = local.has_route53_zone ? aws_route53_record.cloudfront[0].fqdn : "No Route53 zone provided"
}
```

---

## Step 6: Deploy



```bash
terraform init
terraform validate
terraform plan
```

⚠️ **Note for testing:** Modules require real AWS or aren't fully supported in LocalStack.

Review the plan. You'll see Terraform downloading the community modules (stored in `.terraform/`).

Apply:

```bash
terraform apply
```

**Wait time:** 10-15 minutes

---

## Step 7: Validate ACM Certificate

After apply, Terraform outputs DNS records for ACM validation.

Add the CNAME record to your DNS provider, then check:

```bash
aws acm describe-certificate \
  --certificate-arn $(terraform output -raw acm_certificate_arn) \
  --region us-east-1 \
  --query 'Certificate.Status'
```

✅ Expected: `"ISSUED"`

---

## Step 8: Verify DNS Configuration

If you provided a Route53 hosted zone (or Terraform found it automatically), the DNS record is already created for you:

```bash
# Verify the Route53 record was created
aws route53 list-resource-record-sets \
  --hosted-zone-id $(terraform output -raw route53_zone_id) \
  --query "ResourceRecordSets[?Name=='blog.example.com.']"
```

✅ **Expected:** An `A` record (alias) pointing to the CloudFront distribution.

**If you're NOT using Route53:**

You'll need to manually create a DNS record with your DNS provider:

- **Name:** `blog.example.com`
- **Type:** `CNAME`
- **Value:** (from `terraform output -raw cloudfront_domain_name`)

⚠️ **Note:** Some DNS providers don't allow CNAME records at the root domain. In that case, use an `A` record with ALIAS functionality (if supported), or use a subdomain like `www.example.com`.

---

## Step 9: Test

Wait 5-10 minutes for:

- EC2 instances to launch
- ALB health checks to pass
- CloudFront to propagate

Test ALB:

```bash
curl -I http://$(terraform output -raw alb_dns_name)
```

Test Ghost:

```bash
curl -I https://blog.example.com
```

Access the admin panel at `https://blog.example.com/ghost` to complete the Ghost setup:

![Ghost admin setup screen showing site configuration form with fields for site title, full name, email, and password](/media/images/2025/12/01/ghost-screenshot.png)

You'll create your admin account and configure your site title. Ghost walks you through the initial setup.

---

## Troubleshooting

If your Ghost instances aren't coming up healthy in the ALB target group, or if you can't access the site, here's how to debug.

### Check ALB Target Health

```bash
aws elbv2 describe-target-health \
  --target-group-arn $(terraform output -raw alb_target_group_arn) \
  --region us-west-2
```

✅ **Expected:** `State: healthy`

If instances are **unhealthy**, the ALB health check is failing. Common causes:

- Ghost isn't running on port 2368
- Security group blocking ALB → EC2 traffic
- Ghost started before the database was ready

### SSH into EC2 Instance via Session Manager

No SSH keys needed. Use AWS Systems Manager Session Manager:

```bash
# List running EC2 instances
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=ghost-blog" \
  --query 'Reservations[*].Instances[*].[InstanceId,State.Name,PrivateIpAddress]' \
  --output table \
  --region us-west-2

# Start session (replace INSTANCE_ID)
aws ssm start-session --target INSTANCE_ID --region us-west-2
```

⚠️ **Note:** Session Manager requires the EC2 instance to have the `AmazonSSMManagedInstanceCore` policy attached (already included in the Terraform IAM role).

### Check Ghost Service Status

Once connected to the instance:

```bash
# Check Ghost systemd service status
sudo systemctl status ghost_*

# View Ghost logs
sudo journalctl -u ghost_* -f

# Check if Ghost is listening on port 2368
sudo netstat -tlnp | grep 2368
```

✅ **Expected:** Ghost service is `active (running)` and listening on `0.0.0.0:2368`.

### Check Cloud-Init Logs

The `userdata.sh` script runs via **cloud-init** during instance boot. If Ghost isn't installed:

```bash
# Check cloud-init status
cloud-init status

# View complete userdata execution log
sudo tail -100 /var/log/cloud-init-output.log

# View cloud-init detailed processing log
sudo tail -100 /var/log/cloud-init.log

# View the actual userdata script that ran
sudo cat /var/lib/cloud/instance/user-data.txt
```

Common issues in cloud-init logs:

- **Database connection failed**: Aurora endpoint not reachable, security group blocking port 3306
- **SSM Parameter not found**: Parameters not created yet, or IAM role missing permissions
- **Secrets Manager access denied**: IAM role missing `secretsmanager:GetSecretValue` permission
- **Ghost install failed**: Node.js version mismatch, missing dependencies

### Verify Database Connectivity

From the EC2 instance:

```bash
# Fetch database credentials from SSM
DB_HOST=$(aws ssm get-parameter --name "/ghost-blog/db-host" --region us-west-2 --query 'Parameter.Value' --output text)
DB_USER=$(aws ssm get-parameter --name "/ghost-blog/db-username" --region us-west-2 --query 'Parameter.Value' --output text)
SECRET_ARN=$(aws ssm get-parameter --name "/ghost-blog/db-password" --region us-west-2 --query 'Parameter.Value' --output text)
DB_PASS=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --region us-west-2 --query 'SecretString' --output text | jq -r '.password')

# Test connection
mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -e "SELECT 1;"
```

✅ **Expected:** Connection succeeds and returns `1`.

If this fails:

- **Check Aurora security group**: Must allow inbound 3306 from EC2 security group
- **Check Aurora status**: Must be in `available` state
- **Check SSM/Secrets Manager permissions**: IAM role must have read access

### Check CloudFront → ALB Connection

```bash
# Test ALB directly (should work)
curl -I http://$(terraform output -raw alb_dns_name)

# Test CloudFront (should work if DNS is configured)
curl -I https://blog.example.com
```

If ALB works but CloudFront doesn't:

- **ACM certificate not validated**: Check certificate status in ACM console
- **DNS not configured**: A/CNAME record not pointing to CloudFront
- **CloudFront still deploying**: Can take 15-20 minutes after initial creation

### Force Instance Replacement

If an instance is stuck in a bad state:

```bash
# Terminate the instance (ASG will launch a new one)
aws ec2 terminate-instances --instance-ids INSTANCE_ID --region us-west-2

# Or, refresh the entire ASG
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name ghost-blog-asg \
  --region us-west-2
```

The Auto Scaling Group will automatically launch a replacement instance and attach it to the ALB target group.

---

## Cleanup



```bash
terraform destroy

# Clean up
cd ..
rm -rf ghost-production-aws-cloudfront-alb-aurora
```

---

## Production Improvements

These modules already include many production best practices, but you can enhance further:

1. **High availability**: Change `single_nat_gateway = false` in VPC module for NAT GW per AZ
2. **Aurora multi-AZ**: Add `instances = { one = {}, two = {} }` in Aurora module
3. **WAF**: Add `web_acl_id` to CloudFront module
4. **Monitoring**: Most modules support a `monitoring` parameter
5. **State backend**: Store Terraform state in S3:

```terraform
terraform {
  backend "s3" {
    bucket = "my-terraform-state"
    key    = "ghost/terraform.tfstate"
    region = "us-west-2"
  }
}
```

---

## Next Steps

This setup works, but managing EC2 instances, databases, load balancers, and networking manually gets expensive and time-consuming. You're responsible for patching, scaling, monitoring, and troubleshooting every layer of the stack.

In the upcoming series, we'll explore different ways to host Ghost on AWS—each with different trade-offs between control, cost, and operational complexity. Some approaches reduce operational overhead. Others cut costs significantly. A few are over-engineered but instructive for platform teams.

Each approach solves the same problem differently. Understanding the trade-offs helps you choose the right architecture for your workload.

**Related posts:**

- [Complete Introduction to Docker for DevOps Engineers](./complete-introduction-docker-devops-engineers.md) – Start here if you're new to containers
- [Host Your Own Ghost CMS Locally: Multi-Service Stack with Docker Compose](./host-ghost-cms-locally-multi-service-stack-docker-compose.md) – The local setup this post builds on

---

## Conclusion

You've deployed a production Ghost stack on AWS with CloudFront, ALB, Aurora Serverless v2, and Auto Scaling:

- **CloudFront** terminates SSL and caches at the edge
- **ALB** distributes traffic across EC2 instances in multiple AZs
- **Aurora Serverless v2** scales the database from 0 to 1 ACU based on load
- **Auto Scaling Group** maintains instance count and replaces failures

This architecture handles real production traffic, scales horizontally, and survives single-AZ failures. But it's also complex and expensive compared to managed platforms or serverless approaches.

**Key takeaways:**

- CloudFront + ACM replaces Caddy for TLS termination in production
- Two certificates are needed: one for CloudFront (us-east-1), one for ALB (your region)
- Aurora Serverless v2 scales to zero, but NAT Gateways and ALB run 24/7
- Route53 automation creates both certificate validation and CloudFront DNS records
- Use Terraform modules to reduce code and inherit production best practices

In the next post, we'll explore other alternatives that reduce operational overhead and cost.

