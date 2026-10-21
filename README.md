# Build with Brainyl — Hands-On Cloud & AI Labs

Practical, reproducible labs covering **AWS, DevOps, containers, Kubernetes, and AI infrastructure**. Follow the projects with the videos on [Build with Brainyl](https://www.youtube.com/@buildwithbrainyl) and the walkthroughs in this repository's [blog directory](./blog/).

**Start with the lab code.** Each lab has its own directory so you can explore the infrastructure and applications directly.

## Ghost CMS: from containers to ECS

| Lab | Code | Walkthrough |
| --- | --- | --- |
| Deploy Ghost CMS on ECS Fargate with Aurora Serverless and an ALB | [Ghost ECS lab](./ghost_ecs/) | [Step-by-step guide](./blog/ghost-ecs-fargate.md) |
| Extend Ghost with a webhook receiver | [Webhook receiver code](./ghost_ecs/webhooks/) | [Multi-container guide](./blog/ghost-ecs-fargate-webhooks.md) |
| Split services using AWS Cloud Map and Route 53 | [Cloud Map lab](./ghost-ecs-fargate-cloudmap-route53-service-discovery/) | [Service-discovery guide](./blog/ghost-ecs-fargate-service-discovery.md) |
| Connect separate services with ECS Service Connect | [Service Connect lab](./ghost-ecs-fargate-service-connect/) | [Service Connect guide](./blog/ghost-ecs-fargate-service-connect.md) |
| Explore ECS deployments with GitHub OIDC and blue/green strategies | [OIDC blue/green lab](./ecs-fargate-blue-green-deployments-oidc/) | [CI/CD guide](./blog/ecs-blue-green-github-actions-ci-cd.md) |

**Featured beginner-friendly lab:** [Ghost CMS on ECS Fargate](./ghost_ecs/) · [Watch the full video](https://youtu.be/_sy8XUhLaUI)

## Other labs

### Kubernetes and EKS

- [EKS Auto Mode](./eks_auto_mode/) — [Terraform bootstrap guide](./blog/eks-auto-mode-quick-bootstrap-terraform.md)
- [EKS Pod Identity](./eks-pod-identity/) — [Pod Identity guide](./blog/eks-pod-identity-terraform-playbook.md)
- [Container image signing, verification, and policy](./signer_notation_ratify/) — [EKS supply-chain security guide](./blog/secure-eks-workloads-aws-signer-notation-ratify-gatekeeper.md)

### AI and agentic systems

- [Amazon Bedrock AgentCore runtime](./agentcore_runtime/)
- [AgentCore browser automation](./agentcore-browser-automation-demo/) — [Browser automation guide](./blog/aws-agentcore-browser-automation-live-demo.md)
- [AI PDF grading agent with Strands and Lambda](./ai-pdf-grading-agent-strands-lambda/) — [Walkthrough](./blog/pdf-grading-agent-strands-multi-tool-orchestration.md)

### AWS infrastructure and application delivery

- [VPC labs](./vpc/)
- [VPC endpoints](./vpc_endpoint/)
- [VPC peering](./vpc_peering/)
- [GitHub Actions OIDC](./github-oidc/)
- [S3 and CloudFront](./s3_cloudfront/)
- [ECS full-stack deployment](./ecs-full-demo/)
- [Docker Compose](./docker_compose/)

Browse [all lab folders](./) and [all written lab guides](./blog/).

## Getting started

1. Choose a lab directory above and check its guide for prerequisites.
2. Sign in to an AWS account appropriate for experimentation; verify its identity with `aws sts get-caller-identity`.
3. Review Terraform plans and resource costs before deploying anything.
4. Validate the outcome and **destroy billable AWS resources** when finished.

> These are teaching labs. Some intentionally use simplified settings to make the architecture easy to inspect. Review authentication, TLS, access controls, state management, persistence, and cost settings before adapting them to production.

## Follow along

- **YouTube:** [@buildwithbrainyl](https://www.youtube.com/@buildwithbrainyl)
- **Source and written guides:** this GitHub repository

The source code is the primary reference for reproducing the projects. Videos demonstrate the practical build process and troubleshooting.
