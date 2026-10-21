# Ghost CMS on Amazon ECS Fargate

Hands-on Terraform lab for deploying **Ghost CMS on Amazon ECS Fargate**, backed by **Amazon Aurora Serverless v2** and exposed through an **Application Load Balancer (ALB)**.

## Follow the lab

- **Source code:** this `ghost_ecs/` directory
- **Step-by-step written walkthrough:** [Deploy Ghost CMS on ECS Fargate](../blog/ghost-ecs-fargate.md)
- **Video walkthrough:** [Ghost on ECS Fargate with Aurora and ALB](https://youtu.be/_sy8XUhLaUI)
- **Next lab:** [Ghost + webhook receiver in one Fargate task](../blog/ghost-ecs-fargate-webhooks.md)

> The video shows a live, hands-on deployment, including AWS Console steps and troubleshooting. This directory provides a Terraform-based implementation of the architecture; individual commands and clicks may differ from the recording.

## Jump straight to the practical build

Don't need the entire 80-minute live recording? Use these **direct video timestamps** to follow only the parts you need. The [written GitHub lab guide](../blog/ghost-ecs-fargate.md) and Terraform files in this folder remain the source for reproducing the stack.

| What you want to do | Jump to the video |
| --- | --- |
| Understand the complete architecture | [00:00 — Overview](https://youtu.be/_sy8XUhLaUI?t=0) |
| Set up ECS permissions | [10:04 — IAM roles](https://youtu.be/_sy8XUhLaUI?t=604) |
| Prepare the network | [17:31 — VPC with Terraform](https://youtu.be/_sy8XUhLaUI?t=1051) |
| Define the container | [20:41 — ECS task definition](https://youtu.be/_sy8XUhLaUI?t=1241) |
| Deploy the service | [23:14 — ECS cluster and service](https://youtu.be/_sy8XUhLaUI?t=1394) |
| Diagnose an initial failure | [29:25 — Troubleshooting](https://youtu.be/_sy8XUhLaUI?t=1765) |
| Set up the database | [31:11 — Aurora Serverless](https://youtu.be/_sy8XUhLaUI?t=1871) |
| Make the app reachable | [41:18 — Application Load Balancer](https://youtu.be/_sy8XUhLaUI?t=2478) |
| Configure credentials | [48:30 — Secrets Manager](https://youtu.be/_sy8XUhLaUI?t=2910) |
| See the finished result | [1:07:00 — Live Ghost test](https://youtu.be/_sy8XUhLaUI?t=4020) |
| Avoid surprise AWS charges | [1:12:54 — Cleanup](https://youtu.be/_sy8XUhLaUI?t=4374) |

> If you're learning ECS for the first time, watch the [core concepts from 01:38](https://youtu.be/_sy8XUhLaUI?t=98) first. These links point to the **original live video**; the lab code is a Terraform implementation of the same infrastructure, not a frame-by-frame transcript of the AWS Console operations.

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
