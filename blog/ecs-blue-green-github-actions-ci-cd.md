
The [ECS blue/green playbook](./ecs-blue-green-deployments-on-fargate.md) walks through native blue/green deployments on Fargate. The [OIDC federation post](./stop-using-access-keys-github-actions-aws.md) shows how to drop access keys from GitHub Actions entirely. This post connects the two — a GitHub Actions pipeline that builds a container image, pushes it to ECR, and runs `terraform apply` to trigger a blue/green deployment without any stored credentials.

The manual workflow from the previous post had three operator steps: build the image locally, update `terraform.tfvars`, run `terraform apply`. That works for a lab, but it falls apart when multiple engineers are shipping daily. A push to `main` should be all it takes to get a new version into production with the same blue/green safety net.

<iframe width="776" height="437" src="https://player.vimeo.com/video/1177138251" title="Automate ECS Blue/Green Deployments with GitHub Actions and OIDC" frameborder="0" allow="autoplay; fullscreen; picture-in-picture; clipboard-write; encrypted-media" allowfullscreen></iframe>

## What You'll Build

A GitHub Actions CI/CD pipeline triggered on pushes to `main`. The pipeline authenticates to AWS via OIDC, builds and pushes the container image to ECR, then runs `terraform apply` with the new image URI — Terraform handles the task definition update and ECS service deployment.

```
git push → GitHub Actions → OIDC → AWS STS → ECR push → terraform apply → Blue/Green deploy
```

| Component | Purpose |
|---|---|
| GitHub Actions | CI/CD runner — builds, pushes, runs Terraform |
| OIDC federation | Short-lived AWS credentials, no stored secrets |
| ECR | Container registry for the app image |
| Terraform | Manages infrastructure and triggers ECS deployments |
| ECS Fargate | Service with `BLUE_GREEN` deployment strategy |
| S3 | Remote Terraform state backend with native locking |

## Prerequisites

- The ECS blue/green infrastructure from [the previous post](./ecs-blue-green-deployments-on-fargate.md) — VPC, ALB with dual listeners, ECS service with `BLUE_GREEN` strategy
- A GitHub repository containing the FastAPI app and Terraform files from that post
- AWS CLI v2 and Terraform v1.13.4+ with the AWS provider v6.20.0+
- The GitHub OIDC provider already registered in your AWS account (see [OIDC setup](./stop-using-access-keys-github-actions-aws.md))

If you haven't set up the OIDC provider yet, the Terraform in Step 1 handles it.

⚠️ **Caution:** Your `network.tf` must include `lifecycle { ignore_changes = [action] }` on both listener rules and `lifecycle { ignore_changes = [default_action] }` on both listeners. ECS modifies these resources during blue/green deployments. Without `ignore_changes`, each `terraform apply` from CI reverts the listener targets back to their initial state, causing traffic to flip-flop between blue and green. The [previous post](./ecs-blue-green-deployments-on-fargate.md) includes these blocks — make sure your Terraform matches.

## Step 1: Terraform State Backend

The GitHub Actions runner needs access to Terraform state. A local `.tfstate` file won't work — every workflow run starts from a clean checkout. Set up an S3 backend with native S3 locking.

Terraform 1.10+ supports `use_lockfile` — state locking backed by S3 object locking instead of DynamoDB. One fewer resource to manage.

Create the backend resources first (run this once, locally):


```bash
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=us-west-2

aws s3api create-bucket \
  --bucket "tfstate-ecs-bluegreen-${AWS_ACCOUNT_ID}" \
  --region "$AWS_REGION" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION"

aws s3api put-bucket-versioning \
  --bucket "tfstate-ecs-bluegreen-${AWS_ACCOUNT_ID}" \
  --versioning-configuration Status=Enabled
```


Then add the backend configuration to your Terraform. Update the `terraform.tf` from the previous post:


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

  backend "s3" {
    bucket       = "tfstate-ecs-bluegreen-<YOUR_ACCOUNT_ID>"
    key          = "ecs-bluegreen/terraform.tfstate"
    region       = "us-west-2"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.aws_region
}
```


Migrate your existing state to the new backend:


```bash
terraform init -migrate-state
```


### Update `container_image` for CI

The previous post hardcoded a default value for `container_image` in `variables.tf`. In a CI pipeline, the workflow passes the image URI at apply time — so the variable should have no default. Update it in your `variables.tf`:

```terraform
variable "container_image" {
  description = "Container image URI for FastAPI app (provided by CI pipeline)"
  type        = string
}
```

With no default, `terraform apply` requires `-var="container_image=..."` on every run. The GitHub Actions workflow in Step 4 handles this automatically. You can also remove `terraform.tfvars` if you had one — the pipeline supplies all variable values directly.

## Step 2: OIDC Provider and CI Role

The pipeline runs `terraform apply`, which creates and modifies VPCs, ALBs, ECS clusters, IAM roles, and more. That requires broad permissions.

This Terraform attaches `AdministratorAccess` to the OIDC role. The pipeline creates VPCs, ALBs, ECS services, and IAM roles (task execution, ECS infrastructure) — that combination requires IAM write permissions that `PowerUserAccess` does not grant.

⚠️ **Caution:** `AdministratorAccess` is intentionally broad for this walkthrough. In production, replace it with a custom policy scoped to the specific services your Terraform manages — ECS, ECR, EC2 (for VPC/ALB), IAM (for task execution and infrastructure roles), CloudWatch Logs, and S3 (for the state backend). The trust policy already limits who can assume this role to a single repo and branch.


```terraform
terraform {
  required_version = ">= 1.13.4"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.20.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}
```



```terraform
variable "github_org" {
  description = "GitHub organization or username"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}
```



```terraform
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [for cert in data.tls_certificate.github.certificates : lookup(cert, "sha1_fingerprint", "")]
}

resource "aws_iam_role" "github_deploy" {
  name                 = "github-oidc-ecs-deploy"
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "power_user" {
  role       = aws_iam_role.github_deploy.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
```



```terraform
output "role_arn" {
  description = "IAM role ARN for GitHub Actions to assume via OIDC"
  value       = aws_iam_role.github_deploy.arn
}
```


The trust policy is scoped to `refs/heads/main` on a single repository. Only pushes to `main` in that specific repo can assume this role. No other branch, no other repo, no forked PRs.

💡 **Tip:** If you already have the OIDC provider registered from the [OIDC post](./stop-using-access-keys-github-actions-aws.md), import it instead of creating a duplicate: `terraform import aws_iam_openid_connect_provider.github arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com`

### Deploy the role


```bash
terraform init
terraform apply \
  -var="github_org=your-org" \
  -var="github_repo=your-repo"
```


Note the role ARN from the output.

## Step 3: Configure Repository Secrets

The pipeline needs two values from your AWS account. Neither is a long-lived credential.

1. Go to your GitHub repository → **Settings** → **Secrets and variables** → **Actions**
2. Add these repository secrets:

| Secret name | Value | Source |
|---|---|---|
| `AWS_ROLE_TO_ASSUME` | The role ARN from Step 2 output | `terraform output -raw role_arn` |
| `AWS_ACCOUNT_ID` | Your 12-digit AWS account ID | `aws sts get-caller-identity --query Account --output text` |

No access keys. The OIDC token exchange handles authentication at runtime.

## Step 4: GitHub Actions Workflow

This workflow does three things on every push to `main`:

1. Authenticates to AWS via OIDC
2. Builds the container image and pushes it to ECR with the commit SHA as the tag
3. Runs `terraform apply` with the new image URI — Terraform updates the task definition and ECS service, triggering a blue/green deployment


```yaml
name: deploy-ecs-bluegreen

on:
  push:
    branches: [main]notes
    paths:
      - "ecs-fargate-blue-green-deployments-oidc/app/**"
      - "ecs-fargate-blue-green-deployments-oidc/terraform/**"
      - ".github/workflows/deploy-ecs-fargate-bluegreen.yml"

env:
  AWS_REGION: us-west-2
  ECR_REPO: fastapi-bluegreen
  PROJECT_DIR: ecs-fargate-blue-green-deployments-oidc
  TF_WORKING_DIR: ecs-fargate-blue-green-deployments-oidc/terraform

permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: ${{ env.TF_WORKING_DIR }}
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Configure AWS credentials via OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_TO_ASSUME }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Login to ECR
        id: ecr-login
        uses: aws-actions/amazon-ecr-login@v2

      - name: Ensure ECR repository exists
        run: |
          aws ecr describe-repositories \
            --repository-names "$ECR_REPO" \
            --region "$AWS_REGION" 2>/dev/null || \
          
          aws ecr create-repository \
            --repository-name "$ECR_REPO" \
            --region "$AWS_REGION" \
            --encryption-configuration encryptionType=AES256

      - name: Build and push image
        id: build
        working-directory: ${{ env.PROJECT_DIR }}/app
        run: |
          IMAGE_TAG="${GITHUB_SHA::8}"
          IMAGE_URI="${{ secrets.AWS_ACCOUNT_ID }}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}:${IMAGE_TAG}"

          docker buildx build --platform linux/amd64 \
            -t "$IMAGE_URI" \
            --push .

          echo "image_uri=$IMAGE_URI" >> "$GITHUB_OUTPUT"

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.13.4"
          terraform_wrapper: false

      - name: Terraform init
        run: terraform init

      - name: Terraform apply
        run: |
          terraform apply -auto-approve \
            -var="container_image=${{ steps.build.outputs.image_uri }}" 

      - name: Wait for deployment steady state
        run: |
          ECS_CLUSTER=$(terraform output -raw ecs_cluster_name 2>/dev/null || echo "ecs-bluegreen-cluster")
          ECS_SERVICE=$(terraform output -raw ecs_service_name 2>/dev/null || echo "ecs-bluegreen-service")

          echo "Waiting for ECS service to reach steady state..."
          aws ecs wait services-stable \
            --cluster "$ECS_CLUSTER" \
            --services "$ECS_SERVICE"
          echo "Deployment complete."

      - name: Print endpoints
        run: |
          echo "Production: $(terraform output -raw production_url)"
          echo "Test:       $(terraform output -raw test_url)"
```


A few things to note:

- **`paths` filter** — The pipeline runs when files under `ecs-fargate-blue-green-deployments-oidc/app/`, `ecs-fargate-blue-green-deployments-oidc/terraform/`, or the workflow itself change. Both app and infrastructure changes go through the same pipeline.
- **Image tag** — Uses the short Git SHA (`GITHUB_SHA::8`). Every commit gets a unique, traceable tag.
- **`terraform apply`** — Passes the new image URI and version tag as variables. Terraform handles the task definition revision, service update, and blue/green trigger. No `jq` scripting, no manual ECS API calls.
- **`services-stable` wait** — Blocks until ECS finishes the blue/green deployment (including the bake period). If the deployment fails, the step fails and the workflow reports red.

### Add Terraform outputs for the wait step

The workflow reads cluster and service names from Terraform outputs. Add these to your `outputs.tf` from the previous post:


```terraform
output "ecs_cluster_name" {
  value = aws_ecs_cluster.app.name
}

output "ecs_service_name" {
  value = aws_ecs_service.app.name
}
```


## Step 5: Repository Layout

Your repository should look like this:

```
.
├── .github/
│   └── workflows/
│       └── deploy-ecs-fargate-bluegreen.yml
└── ecs-fargate-blue-green-deployments-oidc/
    ├── app/
    │   ├── Dockerfile
    │   ├── main.py
    │   └── pyproject.toml
    └── terraform/
        ├── terraform.tf        ← includes S3 backend config
        ├── variables.tf
        ├── network.tf
        ├── ecs.tf
        ├── outputs.tf
        └── outputs-ci.tf
```

The `ecs-fargate-blue-green-deployments-oidc/app/` directory contains the FastAPI source and Dockerfile from [the ECS blue/green post](./ecs-blue-green-deployments-on-fargate.md). The `terraform/` directory holds the infrastructure — the same files, with the S3 backend added to `terraform.tf`. No `terraform.tfvars` needed — the workflow passes variables at apply time.

## Step 6: Trigger a Deployment

Push a change on `main`:

```bash
git add ecs-fargate-blue-green-deployments-oidc/
git commit -m "update app version"
git push origin main
```

Go to the **Actions** tab in GitHub. You should see the `deploy-ecs-bluegreen` workflow running.

### What happens during the run

1. GitHub issues a short-lived OIDC token for this workflow run
2. The `configure-aws-credentials` action exchanges it for temporary STS credentials scoped to the `github-oidc-ecs-deploy` role
3. The runner authenticates to ECR and pushes the new image tagged with the commit SHA
4. `terraform apply` updates the task definition with the new image and applies the change to the ECS service
5. ECS starts green tasks, routes test listener traffic to them, waits through the bake period, then shifts production traffic
6. The `services-stable` wait confirms the deployment completed before the pipeline finishes

⚠️ **Caution:** The `services-stable` wait blocks until the bake period completes. With a 5-minute bake time, expect the pipeline to take roughly 8–12 minutes depending on image pull and task startup times.

## Step 7: Validate

After the pipeline finishes, confirm the new version is live:


<!--
```bash
PROD_URL="http://<YOUR_ALB_DNS>:80"
TEST_URL="http://<YOUR_ALB_DNS>:8080"

echo "=== Production ==="
curl -fsS "$PROD_URL/"

echo "=== Health check ==="
curl -fsS "$PROD_URL/health"
```
-->


```bash
curl -fsS "http://<YOUR_ALB_DNS>/"
curl -fsS "http://<YOUR_ALB_DNS>/health"
```

✅ **Result:** The production endpoint returns the new version string matching the short commit SHA. The health endpoint confirms the app is running with the expected version.

You can also verify in the AWS console: **ECS** → **Clusters** → **ecs-bluegreen-cluster** → **Services** → **ecs-bluegreen-service** → **Deployments** tab. The completed blue/green deployment shows the new task definition revision.

## Cleanup

To remove the OIDC role and provider:


```bash
terraform destroy \
  -var="github_org=your-org" \
  -var="github_repo=your-repo"
```


To tear down the ECS infrastructure via CI, push a commit that removes the Terraform resources, or run locally:


```bash
terraform destroy -auto-approve
```


Clean up the state backend (S3 bucket) last, since Terraform needs it until all other resources are destroyed:

```bash
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws s3 rb "s3://tfstate-ecs-bluegreen-${AWS_ACCOUNT_ID}" --force
```

💡 **Tip:** If you imported an existing OIDC provider, don't destroy it here — other roles may depend on it. Remove it from state first: `terraform state rm aws_iam_openid_connect_provider.github`

## Production Notes

**Tighten the IAM policy:**

- This walkthrough uses `AdministratorAccess` because Terraform creates IAM roles (task execution, ECS infrastructure) alongside compute and networking resources. In production, replace it with a custom policy scoped to the services Terraform manages: ECS, ECR, EC2 (VPC, ALB, security groups), IAM (role and policy management for task execution), CloudWatch Logs, and S3 (state backend). The narrower the policy, the smaller the impact if a workflow is compromised.

**Branch protection:**

- The IAM trust policy is locked to `refs/heads/main`. Pair this with GitHub branch protection rules — require PR reviews and status checks before merging to `main` so deployments can't be triggered by direct pushes.

**Environment gates:**

- For production workloads, add a GitHub [environment](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment) with required reviewers. Update the IAM trust condition to `repo:ORG/REPO:environment:production` and add `environment: production` to the workflow job.

**Plan before apply:**

- For added safety, split the workflow into two jobs: one that runs `terraform plan` and posts the diff as a PR comment, and a second that runs `terraform apply` after merge. This gives reviewers visibility into infrastructure changes before they land.

**Rollback from CI:**

- If a deployment goes wrong, revert the commit on `main` and push. The pipeline runs again with the previous app code, building and deploying the known-good image through the same blue/green process.

**Image lifecycle:**

- ECR images accumulate. Set up an [ECR lifecycle policy](https://docs.aws.amazon.com/AmazonECR/latest/userguide/LifecyclePolicies.html) to expire untagged images and keep only the last N tagged images.

**Monitoring:**

- Add a [CloudWatch alarm](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/cloudwatch-metrics.html) on ECS service metrics (running task count, target group healthy hosts) so you know if a deployment leaves the service degraded after the bake period.

## Conclusion

- OIDC federation eliminates stored AWS credentials — the pipeline authenticates with short-lived tokens scoped to a single repo and branch
- `terraform apply` from CI means both app changes and infrastructure changes flow through the same pipeline
- `AdministratorAccess` gets you running fast; scope it down to specific services before shipping to production
- Image tags tied to commit SHAs give you traceability from Git history to running containers
- Rollback is a `git revert` away — the same pipeline handles it

See also: [ECS Blue/Green Deployments on Fargate](./ecs-blue-green-deployments-on-fargate.md) | [Stop Using Access Keys in GitHub Actions](./stop-using-access-keys-github-actions-aws.md)
