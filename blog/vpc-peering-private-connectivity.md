
Accessing an internal load balancer in another VPC requires private connectivity. When both VPCs are yours and you need full bidirectional access, VPC peering fits better than PrivateLink.

PrivateLink works well when you're exposing a single service to external accounts or partners. But if you own both networks and need bidirectional access—especially to internal load balancers—peering is the straightforward path. The setup is simple: create the peering connection, update route tables, and configure security groups.

Here's how to build it from scratch. We'll create two isolated VPCs, verify they can't communicate, then add peering and routes to enable private access to an internal ALB.

## What You'll Build

Two VPCs in the same region, each with its own Terraform root. The service VPC runs an internal Application Load Balancer (ALB) and a private EC2 target. It has public subnets with a NAT gateway for patching, but the ALB and instance stay private. The client VPC is fully private—just private subnets and a test instance.

Here's what we'll do:

- Deploy both stacks independently
- Confirm they can't talk before peering
- Create the peering connection and update route tables
- Test connectivity through the internal ALB over private IPs

```
Service VPC (10.10.0.0/16)
  ├─ Public subnets + IGW + NAT (EC2 patching only)
  └─ Private subnets -> Internal ALB -> EC2 target
          │
          └──── VPC Peering (pcx-…)
                  │
Client VPC (10.20.0.0/16)
  └─ Private subnets + EC2 test host (no IGW)
```

## Prerequisites

You'll need Terraform v1.13.4+ with the AWS provider v6.x, AWS CLI v2, and credentials that can create VPCs, EC2, ALBs, and peering connections. We're using **us-west-2** as the default region.

Install the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) for the AWS CLI. You'll use it to connect to EC2 instances via SSM without SSH or public IPs. The plugin requires AWS CLI v1.16.12 or later (v2 includes this).

Pick two non-overlapping CIDRs—we're using `10.10.0.0/16` and `10.20.0.0/16`. Cost is minimal if you destroy after testing. The client VPC uses interface endpoints instead of a NAT gateway to keep costs down and traffic fully private.

The IAM roles here are permissive for demo purposes. Tighten them in production.

## Repository Layout

Split this into two Terraform roots so each VPC has its own state:

```
vpc-peering-demo/
├── client/
│   ├── main.tf
│   ├── outputs.tf
│   └── variables.tf
└── service/
    ├── main.tf
    ├── outputs.tf
    └── variables.tf
```

## Step-by-Step Playbook

### 1) Service VPC with Internal ALB

Start with a VPC that has public subnets for NAT and private subnets for the workload. The ALB and EC2 instance stay private. The NAT gateway lets the instance reach the internet for updates without exposing it publicly. If you want the service VPC fully private, use VPC endpoints for SSM like we do in the client VPC.

```hcl
// service/main.tf
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
  region = var.region
}

module "service_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.5.0"

  name = "service"
  cidr = var.cidr

  azs             = var.azs
  public_subnets  = [for i in range(length(var.azs)) : cidrsubnet(var.cidr, 4, i)]
  private_subnets = [for i in range(length(var.azs)) : cidrsubnet(var.cidr, 4, i + length(var.azs))]

  enable_nat_gateway = true

  enable_dns_support   = true
  enable_dns_hostnames = true
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_security_group" "alb" {
  name        = "service-alb"
  description = "Allow HTTP from peered VPC"
  vpc_id      = module.service_vpc.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.client_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "web" {
  name        = "service-web"
  description = "Allow ALB to reach web"
  vpc_id      = module.service_vpc.vpc_id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "web" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.micro"
  subnet_id              = module.service_vpc.private_subnets[0]
  vpc_security_group_ids = [aws_security_group.web.id]

  user_data = <<-EOF
              #!/bin/bash
              dnf install -y nginx
              echo "<h1>Service VPC via VPC Peering</h1>" > /usr/share/nginx/html/index.html
              systemctl enable --now nginx
              EOF

  metadata_options {
    http_tokens = "required"
  }

  iam_instance_profile = aws_iam_instance_profile.web.name
}

resource "aws_lb" "internal" {
  name               = "service-internal-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = module.service_vpc.private_subnets
}

resource "aws_lb_target_group" "web" {
  name     = "service-web"
  port     = 80
  protocol = "HTTP"
  vpc_id   = module.service_vpc.vpc_id
  health_check {
    path                = "/"
    matcher             = "200"
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_target_group_attachment" "web" {
  target_group_arn = aws_lb_target_group.web.arn
  target_id        = aws_instance.web.id
  port             = 80
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

resource "aws_iam_role" "web" {
  name               = "service-web"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.web.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "web" {
  name = "service-web"
  role = aws_iam_role.web.name
}

output "alb_dns" {
  value = aws_lb.internal.dns_name
}
```

Variables make AZs and CIDRs configurable.

```hcl
// service/variables.tf
variable "region" {
  type    = string
  default = "us-west-2"
}

variable "cidr" {
  type    = string
  default = "10.10.0.0/16"
}

variable "client_cidr" {
  description = "CIDR block of the client VPC allowed into the ALB"
  type        = string
  default     = "10.20.0.0/16"
}

variable "client_vpc_id" {
  description = "VPC ID of the client stack for peering auto-accept"
  type        = string
  default     = ""
}

variable "azs" {
  type    = list(string)
  default = ["us-west-2a", "us-west-2b"]
}
```

### 2) Client VPC (Private Only)

The client VPC is fully private—no internet gateway, just private subnets and an SSM-enabled instance. It starts isolated from the service VPC.

We use VPC interface endpoints for SSM services instead of a NAT gateway. This keeps all traffic private and usually costs less since there's no data transfer charge. More importantly, it removes any internet egress path, which fits the goal of keeping this VPC fully private.

```hcl
// client/main.tf
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
  region = var.region
}

module "client_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.5.0"

  name = "client"
  cidr = var.cidr

  azs             = var.azs
  private_subnets = [for i in range(length(var.azs)) : cidrsubnet(var.cidr, 4, i)]

  enable_nat_gateway = false
  enable_dns_support = true
}

resource "aws_security_group" "endpoints" {
  name        = "client-endpoints"
  description = "Allow interface endpoints from inside the VPC"
  vpc_id      = module.client_vpc.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = module.client_vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.client_vpc.private_subnets
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = module.client_vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.client_vpc.private_subnets
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = module.client_vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.client_vpc.private_subnets
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
}
```

💡 **Why VPC endpoints instead of NAT gateway?** These three endpoints enable SSM Session Manager access without internet egress. A NAT gateway charges hourly plus data transfer costs, while interface endpoints charge hourly with no data transfer fees. More importantly, endpoints keep traffic entirely within AWS's private network, which matches the goal of a fully private client VPC.

```hcl
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_security_group" "client" {
  name        = "client-tester"
  description = "Allow outbound for testing and SSM"
  vpc_id      = module.client_vpc.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "tester" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.micro"
  subnet_id              = module.client_vpc.private_subnets[0]
  vpc_security_group_ids = [aws_security_group.client.id]

  user_data = <<-EOF
              #!/bin/bash
              dnf install -y curl
              EOF

  metadata_options {
    http_tokens = "required"
  }

  iam_instance_profile = aws_iam_instance_profile.tester.name
}

resource "aws_iam_role" "tester" {
  name               = "client-tester"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.tester.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "tester" {
  name = "client-tester"
  role = aws_iam_role.tester.name
}

output "vpc_id" {
  value = module.client_vpc.vpc_id
}

output "subnet_ids" {
  value = module.client_vpc.private_subnets
}

output "tester_instance_id" {
  value = aws_instance.tester.id
}
```

Variables:

```hcl
// client/variables.tf
variable "region" {
  type    = string
  default = "us-west-2"
}

variable "cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["us-west-2a", "us-west-2b"]
}

variable "service_cidr" {
  description = "CIDR block of the service VPC allowed into the client VPC"
  type        = string
  default     = "10.10.0.0/16"
}

variable "peering_id" {
  description = "VPC Peering Connection ID"
  type        = string
  default     = ""
}
```

### 3) Deploy and Prove Isolation

Deploy both stacks:

```bash
cd service
terraform init && terraform apply -auto-approve

cd ../client
terraform init && terraform apply -auto-approve
```

Get the ALB DNS name and client instance ID:

```bash
cd service
ALB_DNS=$(terraform output -raw alb_dns)
echo "ALB DNS: $ALB_DNS"

cd ../client
CLIENT_INSTANCE_ID=$(terraform output -raw tester_instance_id)
echo "Client instance ID: $CLIENT_INSTANCE_ID"
```

Connect to the client instance via SSM Session Manager. The VPC interface endpoints let Session Manager work without a NAT gateway or internet gateway. Once you're in, try curling the ALB DNS name. It should timeout since there's no route to `10.10.0.0/16` yet.

```bash
aws ssm start-session --target $CLIENT_INSTANCE_ID

# inside the session
curl -v http://$ALB_DNS
# -> should hang/fail with connection timeout
```

### 4) Add VPC Peering with Auto-Accept

Create the peering connection from the service stack. Setting `auto_accept = true` means it accepts immediately, and we'll expose the peering ID so the client stack can use it for routing.

```hcl
// service/main.tf (add)
resource "aws_vpc_peering_connection" "client" {
  peer_vpc_id = var.client_vpc_id
  vpc_id      = module.service_vpc.vpc_id
  auto_accept = true

  tags = {
    Name = "service-to-client"
  }
}

output "peering_id" {
  value = aws_vpc_peering_connection.client.id
}
```

Pass the client VPC ID into the service root. Remote state works well for production, but for this demo, command-line variables or a shared `terraform.tfvars` file is simpler:

```bash
# Option 1: Using remote state (recommended for production)
data "terraform_remote_state" "client" {
  backend = "s3"
  config = {
    bucket = "your-terraform-state-bucket"
    key    = "client/terraform.tfstate"
    region = "us-west-2"
  }
}

# Then reference: data.terraform_remote_state.client.outputs.vpc_id

# Option 2: Command-line variable
terraform apply -var="client_vpc_id=vpc-xxxxx"
```

### 5) Update Private Route Tables

Add routes in both VPCs pointing to the peering connection. This enables two-way traffic.

```hcl
// service/main.tf (add)
resource "aws_route" "to_client" {
  for_each = toset(module.service_vpc.private_route_table_ids)

  route_table_id            = each.value
  destination_cidr_block    = var.client_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.client.id
}
```

```hcl
// client/main.tf (add)
resource "aws_route" "to_service" {
  for_each = toset(module.client_vpc.private_route_table_ids)

  route_table_id            = each.value
  destination_cidr_block    = var.service_cidr
  vpc_peering_connection_id = var.peering_id
}
```

Add variables to the client stack for the peering ID and service CIDR. After the service stack creates the peering connection, grab its ID and pass it to the client stack:

```bash
# After service stack creates peering
terraform output -raw peering_id > /tmp/peering_id.txt

# Apply client stack with peering ID
terraform apply -var="peering_id=$(cat /tmp/peering_id.txt)"
```

```hcl
// client/variables.tf (add)
variable "service_cidr" {
  type    = string
  default = "10.10.0.0/16"
}

variable "peering_id" {
  type        = string
  description = "ID of the VPC peering connection created by the service stack"
}
```

Apply the updates in both stacks, then check the route tables in the console to confirm the peering routes are active.

### 6) Re-Test Connectivity

Connect back to the client instance via SSM and curl the ALB DNS name again. This time it should respond immediately over the peering link.

```bash
aws ssm start-session --target $CLIENT_INSTANCE_ID

# inside the session
curl http://$ALB_DNS
# -> <h1>Service VPC via VPC Peering</h1>
```

The response should come back immediately. Traffic flows entirely over private IPs through the peering connection—no internet gateways or public IPs involved.

Peering gives you full bidirectional routing between the VPCs. There are no transitive routes, and CIDRs can't overlap. Any private IP in either VPC can reach the other, subject to security groups and NACLs. Keep security groups tight—if you only need to expose a single service, peering is probably overkill.

## When to Use VPC Endpoint Services Instead

Endpoint services (PrivateLink) are one-way and service-scoped. They require Network Load Balancers or Gateway Load Balancers, not Application Load Balancers. Use them when external accounts or partners need your service without learning your network topology.

Consumers manage their own interface endpoints, so you avoid shared route tables and peering sprawl across multiple accounts. You can also map friendly DNS names to endpoints, which simplifies client consumption.

Peering works when you own both VPCs, want full mesh connectivity, and you're fine with broad routing. If you're just publishing a single service to third parties, use [VPC endpoint services](./vpc-endpoint-service-private-connectivity.md) instead.

## Cleanup

Destroy both stacks to stop the hourly charges.

```bash
cd client && terraform destroy -auto-approve
cd ../service && terraform destroy -auto-approve
```

## Key Takeaways

- VPC peering is the simplest way to share an internal load balancer privately when you own both networks and accept full routing between them.
- Endpoint services (PrivateLink) only support Network or Gateway Load Balancers, not Application Load Balancers. They're built for exposing narrow services to external clients.
- Keep CIDRs non-overlapping, route tables minimal, and security groups scoped to required CIDRs to avoid unintended access.
- Use SSM Session Manager instead of public SSH for both VPCs. Keep the ALB and instances in private subnets.
- VPC interface endpoints for SSM cost less than NAT gateways for private-only VPCs and eliminate internet egress paths entirely.
