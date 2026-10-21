# Amazon ECS Fargate — Watch the Labs in Order

**Build with Brainyl** · [YouTube ECS playlist](https://www.youtube.com/playlist?list=PL5ymUCY9LDOBRP6QSz4KXRjGepIq7RjxJ) · [All cloud labs](./README.md)

A practical, project-based path through Amazon ECS. Start by getting a **Ghost CMS** application running on Fargate. Add a second container, split it into independently deployable services, and explore two ways to connect them privately. Then move on to safer releases, automated CI/CD, edge delivery, and a full-stack capstone.

> **Recommended viewing order, not upload order.** Some recordings were uploaded out of sequence. The steps below reflect what each lesson builds on. These are hands-on livestreams, so durations vary.

## The recommended order

| Step | Watch the lesson | What changes from the previous lab | GitHub materials |
| --- | --- | --- | --- |
| **1 — First deployment** | [Deploy Ghost CMS on ECS Fargate with Aurora & ALB](https://youtu.be/_sy8XUhLaUI) | Get a working Ghost app into an ECS service in private subnets, with Aurora and a public ALB | [Source](./ghost_ecs/) · [Written lab](./blog/ghost-ecs-fargate.md) |
| **2 — Two containers, one task** | [Add a Webhook Receiver to Ghost on Fargate](https://youtu.be/hZwXO2PmAt4) | Add FastAPI webhooks beside Ghost and communicate over localhost in the same task | [Webhook source](./ghost_ecs/webhooks/) · [Written lab](./blog/ghost-ecs-fargate-webhooks.md) |
| **3 — Independent ECS services** | [Split Ghost and Webhooks with Cloud Map + Route 53](https://youtu.be/KO9aOJ_t7js) | Decouple the tasks so they scale independently, with private-DNS service discovery | [Source](./ghost-ecs-fargate-cloudmap-route53-service-discovery/) · [Written lab](./blog/ghost-ecs-fargate-service-discovery.md) |
| **4 — Service Connect** | [Private Communication with ECS Service Connect](https://youtu.be/ShxriLL4Xeo) | Solve the same service-to-service routing problem using Service Connect and its managed proxy layer | [Source](./ghost-ecs-fargate-service-connect/) · [Written lab](./blog/ghost-ecs-fargate-service-connect.md) |
| **5 — Safer releases** | [Native Blue/Green Deployments on ECS Fargate](https://youtu.be/VEhCOvXaAxM) | Move to blue/green with target groups and controlled traffic shifting; introduces a small FastAPI demo app | [Source](./ecs-fargate-blue-green-deployments/) · [Written lab](./blog/ecs-blue-green-deployments-on-fargate.md) |
| **6 — Automated CI/CD** | [GitHub Actions + OIDC for ECS Blue/Green](https://youtu.be/MOPP3awZap4) | Build and push images to ECR, authenticate with OIDC, and deploy using GitHub Actions | [Source](./ecs-fargate-blue-green-deployments-oidc/) · [Written lab](./blog/ecs-blue-green-github-actions-ci-cd.md) |
| **7 — Edge & custom domain** | [CloudFront, TLS, Route 53 for ECS Fargate](https://youtu.be/2mNqPINKRsA) | Extend the CI/CD-deployed FastAPI app with CloudFront caching, HTTPS, and a custom domain | [Source](./ecs-fargate-deployments-oidc-cloudfront/) · [Written lab](./blog/serve-ecs-fargate-cloudfront-custom-domain-route53-terraform.md) |
| **8 — Full-stack capstone** | [Three-Tier ECS Deployment with AppConfig & GitHub Actions](https://youtu.be/zTa52jRcETA) | Combine frontend, backend, database, Service Connect, AppConfig and CI/CD in a larger application | [Application](./ecs-full-demo/fullstack-app/) · [Infrastructure](./ecs-full-demo/infrastructure/) |

## How to follow along

**New to ECS?** Watch **1 → 2 → 3 → 4** in sequence. You'll learn ECS concepts through a single application rather than a collection of unrelated demo containers. Watch lesson 1's [ECS fundamentals at 01:38](https://youtu.be/_sy8XUhLaUI?t=98) if you want a refresher.

**Already comfortable with ECS services?** Start at **5**, then **6 → 7**. The blue/green recording explains the deployment mechanism before the GitHub Actions session automates it. The CloudFront recording uses the CI/CD and OIDC workflow introduced in lesson 6.

**Ready for a bigger project?** Try **8** after the earlier labs. It changes applications on purpose: from Ghost to a multi-service web app, with more realistic deployment and application-configuration concerns.

Each recording includes live troubleshooting, and the corresponding written guide may use Terraform to reproduce infrastructure that was configured interactively during the livestream. Read a lab's prerequisites, review security settings and estimated AWS costs, and destroy temporary resources when finished.

## Key moments from the first lab

- [Start with the ECS task definition — 20:41](https://youtu.be/_sy8XUhLaUI?t=1241)
- [Deploy the ECS cluster and service — 23:14](https://youtu.be/_sy8XUhLaUI?t=1394)
- [Troubleshoot a failed ECS task — 29:25](https://youtu.be/_sy8XUhLaUI?t=1765)
- [Watch the Ghost application go live — 1:07:00](https://youtu.be/_sy8XUhLaUI?t=4020)

## Next: from ECS to Kubernetes

This ECS journey prepares you for the next **Build with Brainyl Kubernetes/EKS** project track. The intention is to revisit familiar deployments, starting with Kubernetes locally before moving to EKS, GitOps, Crossplane, and AI platform workloads. The Kubernetes videos are upcoming; no playlist link is published yet.

**Watch the series:** [ECS Fargate on AWS — From First Deploy to Production CI/CD](https://www.youtube.com/playlist?list=PL5ymUCY9LDOBRP6QSz4KXRjGepIq7RjxJ)
