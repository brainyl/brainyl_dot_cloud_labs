
## What Problem Are We Solving?

Most AWS workloads begin as single-VPC deployments. That approach breaks down when multiple accounts or business units need to call a private service—think billing APIs, internal dashboards, or shared authentication endpoints. Exposing the workload to the internet negates the security model, and layering VPC peering across teams quickly becomes a mess of transitive routing limits, overlapping CIDRs, and lengthy security reviews.

## Solution Overview

[VPC endpoint services](https://docs.aws.amazon.com/vpc/latest/privatelink/endpoint-services-overview.html) wrap the service with a Network Load Balancer (NLB) and publish it through AWS PrivateLink. Consumers spin up interface VPC endpoints in their own subnets and reach the service over AWS's private backbone by using static private IPs.

We'll build the layout end to end with Terraform while keeping the infrastructure modular:

* A **service VPC** that hosts a `t3.micro` Amazon Linux instance behind an internal NLB.
* An **endpoint service** that exposes the NLB to approved principals.
* A **client VPC** that provisions an interface endpoint, connects from a private EC2 instance, and validates the flow with `curl`.

Each Terraform stack lives in its own directory—`service/` and `client/`—so separate teams can manage lifecycle changes without stepping on one another. The configuration sticks to lean, well-scoped modules instead of a monolithic root file.

## Prerequisites

* Terraform 1.6+
* AWS credentials with permissions to create VPCs, EC2 instances, load balancers, and PrivateLink resources.
* An SSM Session Manager-enabled environment (the tutorial uses Amazon Linux 2023 and the `AmazonSSMManagedInstanceCore` role for interactive shell access without public IPs).

## Repository Layout

Create a working directory with separate Terraform roots:

```
privatelink-demo/
├── client/
│   ├── main.tf
│   ├── outputs.tf
│   └── variables.tf
└── service/
    ├── main.tf
    ├── outputs.tf
    └── variables.tf
```

We'll walk through the service stack first, then hook the client to it.

## Service Stack: Private Web App Behind an Endpoint Service

### 1. VPC and Subnet Topology

Use the community VPC module to build a `/16` VPC with two private subnets (spread across AZs for redundancy). Because the EC2 instance only needs private reachability, we skip public subnets and NAT gateways.

```hcl
// service/main.tf
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
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
  private_subnets = [for i in range(length(var.azs)) : cidrsubnet(var.cidr, 4, i)]
  public_subnets  = [for i in range(length(var.azs)) : cidrsubnet(var.cidr, 4, i + length(var.azs))]
  
  enable_nat_gateway = true

  enable_dns_hostnames = true
  enable_dns_support   = true
}
```

Define inputs for the region, CIDR block, and Availability Zones.

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

variable "azs" {
  type    = list(string)
  default = ["us-west-2a", "us-west-2b"]
}

variable "allowed_client_cidr" {
  type        = string
  description = "CIDR block for the client VPC that should be allowed through the NLB security group"
  default     = "10.20.0.0/16"
}

// When you onboard a new client VPC, pass its CIDR block so the NLB accepts traffic from the interface endpoint.
```

The `allowed_client_cidr` variable keeps the NLB locked down to approved consumers. When another team wants access, ask for the CIDR of their client VPC and pass it as a Terraform variable (you can default it to your test client during the walkthrough).

### 2. Stable ENI and EC2 Instance

To give the NLB a consistent target IP, provision an Elastic Network Interface (ENI) in one of the private subnets and attach it to the web server instance. That ENI's private IP becomes the fixed target for the load balancer.

```hcl
// service/main.tf (continued)
resource "aws_network_interface" "web" {
  subnet_id       = module.service_vpc.private_subnets[0]
  security_groups = [aws_security_group.web.id]
}

resource "aws_instance" "web" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.micro"
  iam_instance_profile   = aws_iam_instance_profile.web.name
  network_interface {
    device_index         = 0
    network_interface_id = aws_network_interface.web.id
  }

  user_data = <<-EOF
              #!/bin/bash
              dnf install -y nginx
              echo "<h1>Welcome to the Service VPC</h1>" > /usr/share/nginx/html/index.html
              systemctl enable --now nginx
              EOF
}

resource "aws_security_group" "web" {
  name        = "service-web"
  description = "Allow NLB traffic"
  vpc_id      = module.service_vpc.vpc_id

  ingress {
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = [module.service_vpc.vpc_cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "web" {
  name               = "service-web"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_policy_attachment" "web_ssm" {
  name       = "service-web-ssm"
  roles      = [aws_iam_role.web.name]
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "web" {
  name = "service-web"
  role = aws_iam_role.web.name
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}
```

### 3. Internal NLB with Security Group Support

The AWS NLB module simplifies listeners, target groups, and registrations. Configure the NLB as internal, set the ENI IP as the only target, and attach a security group that only allows traffic from the client VPC's CIDR (we'll output that CIDR so clients can share it with you).

```hcl
module "nlb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "9.8.0"

  name = "service-nlb"

  load_balancer_type = "network"
  internal           = true
  vpc_id             = module.service_vpc.vpc_id
  subnets            = module.service_vpc.private_subnets

  enable_deletion_protection = false
  enable_cross_zone_load_balancing = false # see gotcha section

  # Security Group for NLB (used with PrivateLink)
  enforce_security_group_inbound_rules_on_private_link_traffic = "off"
  security_group_ingress_rules = {
    allow_client_vpc = {
      from_port   = 80
      to_port     = 80
      ip_protocol = "tcp"
      description = "Allow client VPC traffic"
      cidr_ipv4   = var.allowed_client_cidr
    }
  }
  security_group_egress_rules = {
    all = {
      ip_protocol = "-1"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }

  listeners = {
    http = {
      port     = 80
      protocol = "TCP"
      forward = {
        target_group_key = "web"
      }
    }
  }

  target_groups = {
    web = {
      name_prefix       = "svc"
      protocol          = "TCP"
      port              = 80
      target_type       = "ip"
      vpc_id            = module.service_vpc.vpc_id
      target_id         = aws_network_interface.web.private_ip
      preserve_client_ip = true
      health_check = {
        protocol = "TCP"
      }
    }
  }
}

```

  ### 4. Publish the Endpoint Service

Create the endpoint service, link it to the NLB, and allow principals (account IDs) you trust. For testing, allow your own account.

```hcl
resource "aws_vpc_endpoint_service" "web" {
  acceptance_required        = false
  network_load_balancer_arns = [module.nlb.arn]

  allowed_principals = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
}

data "aws_caller_identity" "current" {}
```

Expose the service CIDR, the NLB ARN, and service name for consumers once the endpoint service exists.

```hcl
// service/outputs.tf
output "service_cidr" {
  value = module.service_vpc.vpc_cidr_block
}

output "endpoint_service_name" {
  value = aws_vpc_endpoint_service.web.service_name
}
```

Share these outputs with client teams. They need the service name to create their interface endpoints, and you can validate the CIDR they provide before whitelisting it in `allowed_client_cidr`.

Run `terraform init && terraform apply` inside the `service/` directory. Capture the outputs—especially `endpoint_service_name`—for the client stack.

## Client Stack: Consume the Endpoint Service

### 1. VPC, Subnets, and Interface Endpoint

Spin up a separate VPC with two private subnets. We'll connect only from private IPs, so no internet gateways or NAT are necessary.

```hcl
// client/main.tf
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
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
  
  // You need this to be able to login using SSM since we don't have an interface endpoint for SSM
  public_subnets  = [for i in range(length(var.azs)) : cidrsubnet(var.cidr, 4, i + length(var.azs))]

  enable_nat_gateway = true

  enable_dns_hostnames = true
  enable_dns_support   = true
}
```

Add variables mirroring the service stack, but with a different CIDR range.

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

variable "endpoint_service_name" {
  type        = string
  description = "Service name from the service stack (e.g., com.amazonaws.vpce.us-west-2.vpce-svc-1234567890abcdef)"
}
```

Provision the interface endpoint, placing it in the first private subnet and associating a security group that allows outbound HTTP to the service and HTTPS for Session Manager.

```hcl
resource "aws_security_group" "endpoint" {
  name        = "client-endpoint"
  description = "Allow HTTP/HTTPS egress"
  vpc_id      = module.client_vpc.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [module.client_vpc.vpc_cidr_block]
  }

  # Permit HTTPS so Session Manager can establish a control channel.
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Permit HTTP traffic to the PrivateLink-backed service.
  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_vpc_endpoint" "service" {
  vpc_id            = module.client_vpc.vpc_id
  service_name      = var.endpoint_service_name
  vpc_endpoint_type = "Interface"

  subnet_ids        = [module.client_vpc.private_subnets[0]]
  security_group_ids = [aws_security_group.endpoint.id]
  private_dns_enabled = false
}
```

Export the DNS name so you can curl it later.

```hcl
// client/outputs.tf
output "endpoint_dns_name" {
  value = aws_vpc_endpoint.service.dns_entry[0].dns_name
}
```

### 2. Test EC2 Instance with SSM Access

Launch an Amazon Linux `t3.micro` instance in a private subnet. Attach the SSM core role so you can connect over Session Manager without a bastion host.

```hcl
resource "aws_iam_role" "ssm" {
  name               = "client-ssm"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_policy_attachment" "ssm_core" {
  name       = "client-ssm-core"
  roles      = [aws_iam_role.ssm.name]
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm" {
  name = "client-ssm"
  role = aws_iam_role.ssm.name
}

resource "aws_instance" "tester" {
  ami                  = data.aws_ami.al2023.id
  instance_type        = "t3.micro"
  subnet_id            = module.client_vpc.private_subnets[0]
  iam_instance_profile = aws_iam_instance_profile.ssm.name
  vpc_security_group_ids = [aws_security_group.endpoint.id]

  user_data = <<-EOF
              #!/bin/bash
              dnf install -y curl
              EOF
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}
```

Apply the client stack with `terraform init && terraform apply`, passing the service name captured earlier:

```bash
terraform apply -var "endpoint_service_name=$(terraform -chdir=../service output -raw endpoint_service_name)"
```

Terraform outputs the interface endpoint DNS name. It will resemble `vpce-12345678-abcdefg.vpce-svc-123456789.us-west-2.vpce.amazonaws.com`.

## Validate End-to-End Connectivity

* On your local machine, get the endpoint DNS name from Terraform:

```bash
terraform output -raw endpoint_dns_name
```

Copy the output (it will resemble `vpce-12345678-abcdefg.vpce-svc-123456789.us-west-2.vpce.amazonaws.com`).

* Open the AWS Console, navigate to **Session Manager**, and start a session on the `client` EC2 instance.

* From the Session Manager shell, resolve and curl the endpoint using the DNS name you copied:

```bash
ENDPOINT="vpce-12345678-abcdefg.vpce-svc-123456789.us-west-2.vpce.amazonaws.com"
curl -I $ENDPOINT
curl $ENDPOINT
```

* Replace the `ENDPOINT` value with the DNS name from step 1. You should see the `Welcome to the Service VPC` message coming from the nginx server.

* Because the NLB targets the ENI IP, the response stays entirely on the AWS private network—no internet gateways or public IPs involved.

## Gotcha: Enable Cross-Zone Load Balancing When Scaling Out

Network Load Balancers do not enable cross-zone load balancing by default. If you add instances or ENIs in multiple Availability Zones without turning on `enable_cross_zone_load_balancing`, traffic may stick to a single AZ and fail health checks. In single-target demos the request occasionally lands in another AZ and the curl command times out.

Set `enable_cross_zone_load_balancing = true` on the module when you add more targets or want deterministic behavior across zones:

```hcl
module "nlb" {
  # ...existing settings...
  enable_cross_zone_load_balancing = true
}
```

Re-run `terraform apply` after toggling the flag. With cross-zone balancing enabled, interface endpoints in any AZ can reach healthy targets consistently.

## Clean Up

Destroy both stacks to avoid ongoing EC2 and PrivateLink charges:

```bash
terraform destroy
terraform -chdir=../service destroy
```

You now have a repeatable Terraform pattern for sharing private services across VPCs with AWS PrivateLink. Split the configuration however you need, supply additional target groups or security controls, and onboard more client accounts by adding their principal ARNs to the endpoint service.
