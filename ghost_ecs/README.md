# Ghost CMS on Amazon ECS Fargate

Hands-on Terraform lab for deploying **Ghost CMS on Amazon ECS Fargate**, backed by **Amazon Aurora Serverless v2** and exposed through an **Application Load Balancer (ALB)**.

## Follow the lab

- **Source code:** this `ghost_ecs/` directory
- **Step-by-step written walkthrough:** [Deploy Ghost CMS on ECS Fargate](../blog/ghost-ecs-fargate.md)
- **Video walkthrough:** [Ghost on ECS Fargate with Aurora and ALB](https://youtu.be/_sy8XUhLaUI)
- **Next lab:** [Ghost + webhook receiver in one Fargate task](../blog/ghost-ecs-fargate-webhooks.md)

> The video shows a live, hands-on deployment, including AWS Console steps and troubleshooting. This directory provides a Terraform-based implementation of the architecture; individual commands and clicks may differ from the recording.

## Architecture

```text
Internet
   |
   v
Application Load Balancer (public subnets)
   |
   v
Ghost CMS — ECS Fargate service (private subnets)
   |
   v
Aurora Serverless v2 / MySQL (private subnets)
```

The lab also configures the VPC, security groups, ECS task execution permissions, CloudWatch Logs, and AWS Secrets Manager for the database password.

## Prerequisites

- An AWS account with permission to create VPC, ECS, ELB, RDS, IAM, CloudWatch Logs, and Secrets Manager resources
- AWS CLI v2 configured for the intended account (verify it with `aws sts get-caller-identity`)
- Terraform **1.13.4 or later**

The sample defaults to **`us-west-2`**; adjust `aws_region` in `variables.tf` or supply it via Terraform variables if needed.

## Run the lab

From a checkout of [Build with Brainyl Labs](https://github.com/brainyl/brainyl_dot_cloud_labs):

```bash
cd ghost_ecs
aws sts get-caller-identity
terraform init
terraform fmt -check
terraform validate
terraform plan
terraform apply
terraform output ghost_url
```

Review the plan and expected charges before applying it. Once the ECS service is healthy, open the Ghost URL reported by Terraform. For validation steps and troubleshooting, use the [full lab guide](../blog/ghost-ecs-fargate.md).

## Clean up

AWS resources in this lab can incur charges even when idle, particularly Aurora, the NAT gateway, and the ALB.

```bash
terraform destroy
```

Confirm cleanup in your AWS account when Terraform finishes.

## Important considerations

- **Learning deployment, not a complete production reference.** The ALB listener is HTTP-only; add TLS/ACM before a real deployment.
- **Persistent content:** the sample does not mount persistent storage for Ghost content. Task replacement can lose uploaded files and themes; use EFS or an appropriate storage adapter for production.
- **Access controls:** `admin_cidr` defaults to `0.0.0.0/0` for lab access. Restrict it for real deployments.
- **Terraform state:** generated database credentials can be present in Terraform state even though the ECS task reads its password from Secrets Manager. Protect the state and never commit it to Git.

## Continue the Ghost/ECS journey

After the single-container deployment, continue with the [multi-container Ghost + webhook walkthrough](../blog/ghost-ecs-fargate-webhooks.md), then explore [Cloud Map and Route 53 service discovery](../ghost-ecs-fargate-cloudmap-route53-service-discovery/) and [ECS Service Connect](../ghost-ecs-fargate-service-connect/).

[Back to all labs](../README.md)
