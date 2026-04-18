
In [Take Ghost CMS to Production on AWS: CloudFront, ALB, and Aurora Serverless](./ghost-production-aws-cloudfront-alb-aurora.md), we deployed a production Ghost blog using NAT Gateways for outbound internet access from private subnets. That setup works, but NAT Gateways are expensive—especially in multi-AZ configurations.

NAT instances provide the same functionality at 70-90% lower cost. Your Ghost EC2 instances still pull package updates, connect to external APIs, and access the internet—but through self-managed EC2 instances instead of AWS-managed NAT Gateways.

This post shows you the complete Ghost production deployment with NAT instances. Everything is included—VPC, NAT instance module, ALB, Aurora, CloudFront. The full Terraform configuration is provided.

## What You'll Build

The same production Ghost deployment from the previous post, with NAT instances handling outbound traffic:

**Architecture:**

```
CloudFront (us-east-1)
       ↓
Application Load Balancer (us-west-2)
       ↓
Auto Scaling Group (Ghost EC2 instances in private subnets)
       ↓
Aurora Serverless v2 (database subnets)

Outbound internet access:
Private Subnets → NAT Instances (t4g.nano) → Internet Gateway
```

| Component | Change from Previous Post |
|-----------|---------------------------|
| VPC | **NAT instances instead of NAT Gateways** |
| ALB | No change |
| ASG | No change |
| Aurora | No change |
| CloudFront | No change |
| ACM | No change |

**The only difference:** Private subnets route outbound traffic through NAT instances (EC2) instead of NAT Gateways (AWS-managed service).

## Prerequisites

- **AWS account** with appropriate permissions
- **Terraform** ≥ v1.13.4
- **AWS CLI** v2 configured
- **Domain name** with DNS access
- **Region**: `us-west-2` (adjust as needed)

**Cost**: Approximately 70-90% lower egress costs compared to NAT Gateways. Destroy resources after testing.

---

## Why NAT Instances for Ghost?

Ghost EC2 instances in private subnets need outbound internet access for:

- **Package updates** – `apt update`, `npm install`
- **Ghost-CLI installation** – Downloads Ghost from npm registry
- **Node.js installation** – Downloads from NodeSource repository
- **External APIs** – Email services, analytics, webhooks

Both NAT Gateways and NAT instances handle this traffic. The choice depends on your priorities: operational simplicity versus cost optimization.

### NAT Gateways: Managed Simplicity

**Benefits:**

- ✅ **Fully managed by AWS** – No patching, no monitoring, no instance management
- ✅ **Automatic scaling** – Scales to 100 Gbps without configuration
- ✅ **Built-in high availability** – AWS handles failover within an AZ
- ✅ **No capacity planning** – Never worry about instance sizing
- ✅ **Consistent performance** – Predictable throughput and latency
- ✅ **Compliance-friendly** – Some organizations require AWS-managed services

**Trade-offs:**

- ❌ Higher hourly costs (per NAT Gateway)
- ❌ Per-GB data processing fees
- ❌ No control over configuration or routing behavior

**Best for:**

- Production workloads where operational overhead matters more than cost
- High-throughput applications (multiple TB/month egress)
- Teams without dedicated infrastructure management
- Compliance requirements for managed services

### NAT Instances: Cost-Optimized Control

**Benefits:**

- ✅ **70-90% lower costs** for moderate traffic workloads
- ✅ **Full control** over instance type, AMI, and configuration
- ✅ **Flexible sizing** – Start with `t4g.nano`, scale as needed
- ✅ **Custom routing** – Add packet inspection, firewall rules, or logging
- ✅ **Predictable billing** – Instance costs don't vary with traffic

**Trade-offs:**

- ❌ Requires patching and OS updates
- ❌ Need to monitor CPU, network, and health
- ❌ Manual capacity planning (choose instance type)
- ❌ Single point of failure per AZ (mitigated with Auto Scaling Groups)

**Best for:**

- Cost-sensitive production workloads with moderate egress traffic
- Development and test environments
- Teams already managing EC2 infrastructure
- Workloads with predictable, steady traffic patterns

### Why NAT Instances Work Well for Ghost

For a production Ghost blog, NAT instances are a good fit because:

1. **Predictable traffic** – Mostly package updates during deployments, not continuous high-volume egress
2. **Already managing EC2** – You're running Ghost on EC2, so adding NAT instance management is incremental
3. **Moderate egress** – Ghost blogs typically transfer less data than the break-even point where NAT Gateways become cheaper
4. **Cost matters** – For 24/7 operation, the hourly savings add up quickly

If your Ghost blog grows to handle very high traffic (multiple TB/month egress) or you prefer zero operational overhead, NAT Gateways remain a solid choice. This post shows you how to deploy with NAT instances—you can always switch back to NAT Gateways by changing a few lines of Terraform.

---

## Project Structure

```
ghost-production-nat-instances/
├── modules/
│   └── nat-instance/
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
├── main.tf
├── variables.tf
├── outputs.tf
├── terraform.tf
├── userdata.sh
└── terraform.tfvars
```

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
  description = "ARN of an existing validated ACM certificate in us-east-1"
  type        = string
  default     = null
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID"
  type        = string
  default     = null
}

# NAT instance configuration
variable "nat_instance_type" {
  description = "Instance type for NAT instances"
  type        = string
  default     = "t4g.nano"
}

variable "nat_instance_ami" {
  description = "AMI ID for NAT instances (fck-nat ARM64 in us-west-2)"
  type        = string
  default     = "ami-0aac6113247ca0b3f"
}
```


Create `terraform.tfvars`:



```terraform
domain_name = "lab.brainyl.cloud"

# Optional: Override defaults
# project_name       = "my-ghost-blog"
# aws_region         = "us-west-2"
# ec2_instance_type  = "t3.small"
# nat_instance_type  = "t4g.nano"
```


---

## Step 3: NAT Instance Module

Create the NAT instance module first. This module creates EC2 instances configured for NAT functionality.

### modules/nat-instance/main.tf

Create `modules/nat-instance/main.tf`:



```terraform
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.0"
    }
  }
}

locals {
  create_instances = var.create && var.nat_count > 0
}

################################################################################
# Security Group
################################################################################

resource "aws_security_group" "this" {
  count       = var.create ? 1 : 0
  name        = "${var.name}-nat-instance-sg"
  description = "Security group for NAT instances"
  vpc_id      = var.vpc_id

  tags = merge({
    Name = "${var.name}-nat-instance-sg"
  }, var.tags)
}

resource "aws_security_group_rule" "ingress" {
  for_each = var.create ? toset(var.allowed_inbound_cidrs) : toset([])

  type              = "ingress"
  security_group_id = aws_security_group.this[0].id
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = [each.value]
  description       = "Allow all traffic from ${each.value}"
}

resource "aws_security_group_rule" "egress_ipv4" {
  count = var.create ? 1 : 0

  type              = "egress"
  security_group_id = aws_security_group.this[count.index].id
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Allow all outbound IPv4 traffic"
}

resource "aws_security_group_rule" "egress_ipv6" {
  count = var.create ? 1 : 0

  type              = "egress"
  security_group_id = aws_security_group.this[count.index].id
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  ipv6_cidr_blocks  = ["::/0"]
  description       = "Allow all outbound IPv6 traffic"
}

################################################################################
# NAT Instances
################################################################################

resource "aws_instance" "this" {
  count = local.create_instances ? var.nat_count : 0

  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = element(var.public_subnet_ids, var.single_nat_gateway ? 0 : count.index)
  associate_public_ip_address = true
  source_dest_check           = false  # CRITICAL: Must be false for NAT functionality
  vpc_security_group_ids      = aws_security_group.this[*].id

  tags = merge({
    Name = var.single_nat_gateway ? "${var.name}-nat-instance" : format(
      "%s-nat-instance-%s",
      var.name,
      element(var.azs, var.single_nat_gateway ? 0 : count.index)
    )
  }, var.tags)

  lifecycle {
    create_before_destroy = true
  }
}

################################################################################
# Elastic IPs
################################################################################

resource "aws_eip" "this" {
  count = local.create_instances ? var.nat_count : 0

  domain   = "vpc"
  instance = element(aws_instance.this[*].id, count.index)

  tags = merge({
    Name = var.single_nat_gateway ? "${var.name}-nat-instance-eip" : format(
      "%s-nat-instance-eip-%s",
      var.name,
      element(var.azs, var.single_nat_gateway ? 0 : count.index)
    )
  }, var.tags)

  depends_on = [aws_instance.this]
}
```


### modules/nat-instance/variables.tf

Create `modules/nat-instance/variables.tf`:



```terraform
variable "create" {
  description = "Controls whether NAT instances should be created"
  type        = bool
  default     = false
}

variable "name" {
  description = "Name prefix applied to NAT instance resources"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the NAT instances will be deployed"
  type        = string
  default     = null
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs where NAT instances can be launched"
  type        = list(string)
  default     = []
}

variable "azs" {
  description = "List of availability zones aligned with the provided public subnets"
  type        = list(string)
  default     = []
}

variable "nat_count" {
  description = "Number of NAT instances to create"
  type        = number
  default     = 0
}

variable "single_nat_gateway" {
  description = "Whether a single NAT instance should be shared across AZs"
  type        = bool
  default     = false
}

variable "instance_type" {
  description = "Instance type used for the NAT instances"
  type        = string
  default     = "t4g.nano"
}

variable "ami_id" {
  description = "AMI ID used for the NAT instances (must support IP forwarding)"
  type        = string
  default     = "ami-0aac6113247ca0b3f"
}

variable "allowed_inbound_cidrs" {
  description = "CIDR blocks allowed to send traffic to the NAT instances"
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to all NAT instance resources"
  type        = map(string)
  default     = {}
}
```


### modules/nat-instance/outputs.tf

Create `modules/nat-instance/outputs.tf`:



```terraform
output "nat_instance_ids" {
  description = "List of NAT instance IDs"
  value       = aws_instance.this[*].id
}

output "nat_instance_public_ips" {
  description = "List of NAT instance Elastic IP addresses"
  value       = aws_eip.this[*].public_ip
}

output "nat_instance_private_ips" {
  description = "List of NAT instance private IP addresses"
  value       = aws_instance.this[*].private_ip
}

output "nat_instance_network_interface_ids" {
  description = "List of NAT instance primary network interface IDs"
  value       = aws_instance.this[*].primary_network_interface_id
}

output "security_group_id" {
  description = "Security group ID for NAT instances"
  value       = try(aws_security_group.this[0].id, null)
}
```


💡 **Tip:** The fck-nat AMI (`ami-0aac6113247ca0b3f`) is pre-configured for NAT functionality with automatic updates. It's optimized for ARM64 instances and maintained by the community.

---

## Step 4: Main Infrastructure

Now create the main infrastructure file. This is where we build the VPC, create NAT instances, and deploy all the Ghost infrastructure.

Create `main.tf`:




```terraform
################################################################################
# VPC with Public, Private, and Database Subnets
################################################################################

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name    = "${var.project_name}-vpc"
    Project = var.project_name
  }
}

################################################################################
# Internet Gateway
################################################################################

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name    = "${var.project_name}-igw"
    Project = var.project_name
  }
}

################################################################################
# Public Subnets
################################################################################

resource "aws_subnet" "public" {
  count = length(var.availability_zones)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name    = "${var.project_name}-public-${var.availability_zones[count.index]}"
    Project = var.project_name
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name    = "${var.project_name}-public-rt"
    Project = var.project_name
  }
}

resource "aws_route" "public_internet_gateway" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = length(var.availability_zones)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

################################################################################
# Private Subnets
################################################################################

resource "aws_subnet" "private" {
  count = length(var.availability_zones)

  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + length(var.availability_zones))
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name    = "${var.project_name}-private-${var.availability_zones[count.index]}"
    Project = var.project_name
  }
}

resource "aws_route_table" "private" {
  count = length(var.availability_zones)

  vpc_id = aws_vpc.this.id

  tags = {
    Name    = "${var.project_name}-private-rt-${var.availability_zones[count.index]}"
    Project = var.project_name
  }
}

resource "aws_route_table_association" "private" {
  count = length(var.availability_zones)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

################################################################################
# Database Subnets
################################################################################

resource "aws_subnet" "database" {
  count = length(var.availability_zones)

  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + (2 * length(var.availability_zones)))
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name    = "${var.project_name}-database-${var.availability_zones[count.index]}"
    Project = var.project_name
  }
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = aws_subnet.database[*].id

  tags = {
    Name    = "${var.project_name}-db-subnet-group"
    Project = var.project_name
  }
}

################################################################################
# NAT Instances Module
################################################################################

module "nat_instances" {
  source = "./modules/nat-instance"

  create             = true
  name               = var.project_name
  vpc_id             = aws_vpc.this.id
  public_subnet_ids  = aws_subnet.public[*].id
  azs                = var.availability_zones
  nat_count          = length(var.availability_zones)
  single_nat_gateway = false  # One NAT instance per AZ for production
  instance_type      = var.nat_instance_type
  ami_id             = var.nat_instance_ami
  
  # Allow traffic from VPC CIDR
  allowed_inbound_cidrs = [var.vpc_cidr]

  tags = {
    Project = var.project_name
  }
}

################################################################################
# Routes to NAT Instances
################################################################################

resource "aws_route" "private_nat_instance" {
  count = length(var.availability_zones)

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = element(module.nat_instances.nat_instance_network_interface_ids, count.index)

  depends_on = [module.nat_instances]
}

################################################################################
# Security Groups
################################################################################

module "alb_security_group" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = "${var.project_name}-alb-sg"
  description = "Security group for ALB"
  vpc_id      = aws_vpc.this.id

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
  vpc_id      = aws_vpc.this.id

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
  vpc_id      = aws_vpc.this.id

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

  vpc_id                 = aws_vpc.this.id
  db_subnet_group_name   = aws_db_subnet_group.this.name
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
  vpc_id             = aws_vpc.this.id
  subnets            = aws_subnet.public[*].id
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
      create_attachment    = false

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
  owners      = ["099720109477"]

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

  vpc_zone_identifier = aws_subnet.private[*].id
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

module "acm_cloudfront" {
  source  = "terraform-aws-modules/acm/aws"
  version = "~> 5.0"

  providers = {
    aws = aws.us_east_1
  }

  domain_name = var.domain_name
  zone_id     = local.route53_zone_id

  validation_method      = "DNS"
  create_route53_records = local.has_route53_zone
  wait_for_validation    = local.has_route53_zone

  tags = {
    Project = var.project_name
    Purpose = "CloudFront"
  }
}

module "acm_alb" {
  source  = "terraform-aws-modules/acm/aws"
  version = "~> 5.0"

  domain_name = var.domain_name
  zone_id     = local.route53_zone_id

  validation_method      = "DNS"
  create_route53_records = local.has_route53_zone
  wait_for_validation    = local.has_route53_zone

  tags = {
    Project = var.project_name
    Purpose = "ALB"
  }
}

locals {
  acm_certificate_arn_cloudfront = var.acm_certificate_arn != null ? var.acm_certificate_arn : module.acm_cloudfront.acm_certificate_arn
  acm_certificate_arn_alb        = module.acm_alb.acm_certificate_arn
}

################################################################################
# CloudFront Cache Policies
################################################################################

resource "aws_cloudfront_cache_policy" "static_assets_cache" {
  name    = "${var.project_name}-static-assets-cache-policy"
  comment = "Cache policy for static assets with 1 year TTL"

  min_ttl     = 86400
  default_ttl = 31536000
  max_ttl     = 31536000

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

resource "aws_cloudfront_origin_request_policy" "alb_origin_policy" {
  name    = "${var.project_name}-alb-origin-request-policy"
  comment = "Origin request policy for ALB (Ghost) origin"

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

resource "aws_cloudfront_origin_request_policy" "static_assets_policy" {
  name    = "${var.project_name}-static-assets-origin-request-policy"
  comment = "Origin request policy for static assets"

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


---

## Step 5: Userdata Script

The userdata script is identical to the previous post. Ghost instances don't know they're using NAT instances.

Create `userdata.sh`:




```bash
#!/bin/bash
set -e

PROJECT_NAME="${project_name}"
AWS_REGION="${aws_region}"
DOMAIN_NAME="${domain_name}"

apt-get update
apt-get upgrade -y

# Install AWS CLI v2
apt-get install -y unzip curl
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/awscliv2.zip /tmp/aws

apt-get install -y jq

# Fetch database connection details
DB_HOST=$(aws ssm get-parameter --name "/$PROJECT_NAME/db-host" --region $AWS_REGION --query 'Parameter.Value' --output text)
DB_NAME=$(aws ssm get-parameter --name "/$PROJECT_NAME/db-name" --region $AWS_REGION --query 'Parameter.Value' --output text)
DB_USER=$(aws ssm get-parameter --name "/$PROJECT_NAME/db-username" --region $AWS_REGION --query 'Parameter.Value' --output text)

SECRET_ARN=$(aws ssm get-parameter --name "/$PROJECT_NAME/db-password" --region $AWS_REGION --query 'Parameter.Value' --output text)
DB_PASS=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --region $AWS_REGION --query 'SecretString' --output text | jq -r '.password')

# Install Node.js 22
apt-get install -y ca-certificates curl gnupg
mkdir -p /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
NODE_MAJOR=22
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list
apt-get update
apt-get install nodejs -y

apt-get install -y mysql-client
npm install ghost-cli@latest -g

mkdir -p /var/www/ghost
chown ubuntu:ubuntu /var/www/ghost
chmod 775 /var/www/ghost

sudo -u ubuntu env DOMAIN_NAME="$DOMAIN_NAME" DB_HOST="$DB_HOST" DB_NAME="$DB_NAME" DB_USER="$DB_USER" DB_PASS="$DB_PASS" NODE_ENV="production" bash <<'EOF'
set -e
cd /var/www/ghost
export NODE_ENV="production"

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

# Test database connectivity (optional - Ghost will fail to start if DB is unreachable)
echo "Testing database connectivity..."
mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -e "SELECT 1;" 2>&1 || {
  echo "WARNING: Cannot connect to database yet. Ghost will retry when it starts."
  echo "Host: $DB_HOST"
  echo "User: $DB_USER"
  echo "Database: $DB_NAME"
}

ghost setup nginx --no-prompt
ghost start
EOF
```


---

## Step 6: Outputs

Create `outputs.tf`:



```terraform
output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.this.id
}

output "nat_instance_ids" {
  description = "NAT instance IDs"
  value       = module.nat_instances.nat_instance_ids
}

output "nat_instance_public_ips" {
  description = "NAT instance Elastic IP addresses"
  value       = module.nat_instances.nat_instance_public_ips
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

output "domain_name" {
  description = "Domain name pointing to CloudFront"
  value       = var.domain_name
}
```


---

## Step 7: Deploy



```bash
terraform init
terraform validate
terraform plan
```

Review the plan. You should see:

- VPC with public/private/database subnets
- **NAT instances** (2 in different AZs)
- Elastic IPs attached to NAT instances
- Route table entries pointing private subnets to NAT instances
- ALB, ASG, Aurora, CloudFront (same as before)

Apply:

```bash
terraform apply
```


**Wait time:** 10-15 minutes

---

## Step 8: Validate NAT Instance Functionality

### Check NAT Instance Status

```bash
terraform output nat_instance_ids
terraform output nat_instance_public_ips

# Check instance status
aws ec2 describe-instances \
  --instance-ids $(terraform output -json nat_instance_ids | jq -r '.[0]') \
  --query 'Reservations[0].Instances[0].[InstanceId,State.Name,PublicIpAddress]' \
  --output table
```

✅ **Expected:** Instance state is `running`, has public IP.

### Verify Source/Destination Check is Disabled

```bash
aws ec2 describe-instance-attribute \
  --instance-id $(terraform output -json nat_instance_ids | jq -r '.[0]') \
  --attribute sourceDestCheck \
  --query 'SourceDestCheck.Value'
```

✅ **Expected:** `false`

### Test Ghost Instance Outbound Connectivity

```bash
# Get Ghost instance ID
GHOST_INSTANCE=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=ghost-blog" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

# Connect via Session Manager
aws ssm start-session --target $GHOST_INSTANCE

# Inside the instance, test outbound connectivity
curl -I https://www.google.com

# Check what public IP is being used (should be NAT instance EIP)
curl https://checkip.amazonaws.com
```

✅ **Expected:** Public IP matches one of the NAT instance Elastic IPs.

---

## Step 9: Verify Ghost is Running

```bash
# Test ALB
curl -I http://$(terraform output -raw alb_dns_name)

# Test CloudFront (after DNS propagation)
curl -I https://lab.brainyl.cloud

# Access Ghost admin
open https://lab.brainyl.cloud/ghost
```

Ghost EC2 instances pull packages and install Ghost through the NAT instances. The userdata script runs the same commands—the instances don't know they're using NAT instances instead of NAT Gateways.

---

## Monitoring NAT Instances

### CloudWatch Metrics

```bash
NAT_INSTANCE_ID=$(terraform output -json nat_instance_ids | jq -r '.[0]')

# Check CPU utilization
aws cloudwatch get-metric-statistics \
  --namespace AWS/EC2 \
  --metric-name CPUUtilization \
  --dimensions Name=InstanceId,Value=$NAT_INSTANCE_ID \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Average
```

### Set Up CloudWatch Alarms

```bash
# Alarm for high CPU
aws cloudwatch put-metric-alarm \
  --alarm-name ghost-nat-instance-high-cpu \
  --alarm-description "NAT instance CPU > 80%" \
  --metric-name CPUUtilization \
  --namespace AWS/EC2 \
  --statistic Average \
  --period 300 \
  --threshold 80 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 2 \
  --dimensions Name=InstanceId,Value=$NAT_INSTANCE_ID
```

---

## Troubleshooting

### Ghost Instances Can't Pull Packages

**Check route tables:**

```bash
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$(terraform output -raw vpc_id)" \
  --query 'RouteTables[?Tags[?Key==`Name` && contains(Value, `private`)]].[RouteTableId,Routes]'
```

✅ **Expected:** Route for `0.0.0.0/0` pointing to NAT instance ENI.

**Check source/destination check:**

```bash
aws ec2 describe-instance-attribute \
  --instance-id $(terraform output -json nat_instance_ids | jq -r '.[0]') \
  --attribute sourceDestCheck
```

✅ **Expected:** `"Value": false`

### NAT Instance High CPU

If CPU is consistently above 70%, upgrade the instance type:

```terraform
# Edit terraform.tfvars
nat_instance_type = "t4g.micro"

# Apply changes
terraform apply
```

---

## Cleanup



```bash
terraform destroy
```


---

## Cost Comparison

For the Ghost production setup with 2 AZs:

### NAT Gateways (Previous Post)

- 2 NAT Gateways running 24/7
- Hourly charges plus per-GB data processing
- Fully managed, no operational overhead

### NAT Instances (This Post)

- 2 `t4g.nano` instances running 24/7
- Hourly instance charges plus standard EC2 egress rates
- Requires monitoring and patching
- **Typical savings: 70-90% for moderate traffic**

---

## Conclusion

You've deployed the same production Ghost CMS infrastructure with one key change: NAT instances replace NAT Gateways. Everything else—CloudFront, ALB, Aurora Serverless, Auto Scaling Groups—works identically.

NAT instances reduce egress costs by 70-90% for workloads with moderate traffic. The trade-off is operational overhead—you're responsible for patching, monitoring, and replacing failed instances. For a Ghost blog where you're already managing EC2 instances, this is a reasonable trade-off.

**Key takeaways:**

- Same Ghost production architecture, different NAT solution
- NAT instances provide 70-90% cost savings for moderate egress traffic
- Use `t4g.nano` for cost optimization, upgrade if needed
- One NAT instance per AZ for production high availability
- Monitor CPU and network metrics to detect capacity issues
- Complete, self-contained Terraform code—copy, paste, deploy

The complete code in this post gives you everything needed to deploy Ghost with NAT instances. No external modules to track down, no missing pieces.

**Related posts:**

- [Take Ghost CMS to Production on AWS: CloudFront, ALB, and Aurora Serverless](./ghost-production-aws-cloudfront-alb-aurora.md) – The base architecture this post optimizes
