
You already have Amazon EKS Auto Mode ready from the [quick bootstrap playbook](./eks-auto-mode-quick-bootstrap-terraform.md), but pushing images to ECR isn't enough to secure your workloads. Without signature verification, you can't prove that the container running in your cluster matches the one you built—or that it hasn't been tampered with.

AWS Signer and Notation provide cryptographic attestations that the build you shipped is the one actually running. Ratify and OPA Gatekeeper enforce these signatures at admission time, denying every pod that lacks a trusted signature before it starts. This guide connects those components together so the last mile of your software supply chain is automated and auditable instead of relying on manual review.

You'll create an AWS Signer profile, configure Notation for both local and CI signing, and let GitHub Actions sign releases without long-lived credentials. Ratify plugs into Gatekeeper to verify each pod admission request, so unsigned workloads fail immediately. By the end, you'll have enforced signature verification across your EKS workloads with a clean teardown path.

## What You’ll Build

By the end, your repositories sign containers with AWS Signer, push them to ECR, and Ratify verifies every deployment before it runs. Gatekeeper blocks unsigned workloads, and signed ones are admitted with an auditable signature trail. You will test both scenarios so you can see the admission controller in action, then tear everything down to avoid drift and costs.

```
Client → GitHub Actions (OIDC) → AWS (ECR, Signer) → EKS (Ratify + Gatekeeper) → Running, verified pod
```

| Component            | Purpose                               |
|----------------------|----------------------------------------|
| Terraform            | Provision EKS Auto Mode                |
| GitHub Actions       | Build, sign, and push container        |
| AWS Signer           | Signing authority for the container    |
| Ratify + Gatekeeper  | Admission control / verify images      |

## Prerequisites

* AWS account in `us-west-2` with permissions to manage ECR, Signer, IAM, and EKS.
* Existing Auto Mode EKS cluster from the [EKS Auto Mode Quick Bootstrap with Terraform](./eks-auto-mode-quick-bootstrap-terraform.md) guide. The EKS Pod Identity agent is pre-installed on Auto Mode clusters.
* `aws` CLI v2, `kubectl` 1.34+, `docker`, `notation` 2.0+, and `terraform` 1.13.4+ installed locally (follow the <a href="https://notaryproject.dev/docs/user-guides/installation/cli/" target="_blank" rel="noreferrer">Notation CLI setup guide</a> to install version 2.0.0 or newer). Terraform AWS provider must be v6.20.0+ for Pod Identity support.
* Go 1.21+ installed (required for building the AWS Signer Notation plugin from source in Step 2). Install from <a href="https://go.dev/dl/" target="_blank" rel="noopener">go.dev</a> if needed.
* GitHub repository with Actions enabled and OIDC trust to AWS (follow the steps in [our guide on using GitHub Actions OIDC roles securely](./stop-using-access-keys-github-actions-aws.md)).
* Estimated cost: under $5 if you destroy test resources after validation (Signer profile is free, ECR storage and EKS nodes accrue the charges).

## Step-by-Step Playbook for Securing EKS Workloads

### 1. Provision EKS Auto Mode, ECR, and Signer with Terraform

Run this playbook from the same Terraform repository you used for the [Auto Mode bootstrap](./eks-auto-mode-quick-bootstrap-terraform.md). Extend `main.tf` so Terraform creates the ECR repository and AWS Signer profile alongside the cluster:

```hcl
terraform {
  required_version = ">= 1.13.4"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.20.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.27.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.11.0"
    }
  }
}

provider "aws" {
  region = var.region
}

module "eks_auto_mode" {
  # Reuse the module definition from the Auto Mode quick bootstrap post
  source = "./modules/eks-auto-mode"

  name   = var.cluster_name
  region = var.region
}

resource "aws_ecr_repository" "secure_demo" {
  name                 = var.repository_name
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  encryption_configuration {
    encryption_type = "KMS"
  }
}

resource "aws_signer_signing_profile" "eks_secure" {
  name        = var.signing_profile_name
  platform_id = "Notation-OCI-SHA384-ECDSA"

  signature_validity_period {
    value = 135
    type  = "DAYS"
  }
}

output "repository_url" {
  value = aws_ecr_repository.secure_demo.repository_url
}

output "signing_profile_arn" {
  value = aws_signer_signing_profile.eks_secure.arn
}
```

Add supporting variables so the configuration stays reusable:

```hcl
// variables.tf
variable "region" {
  type    = string
  default = "us-west-2"
}

variable "cluster_name" {
  type    = string
  default = auto-mode-lab
}

variable "repository_name" {
  type    = string
  default = "secure-demo"
}

variable "signing_profile_name" {
  type    = string
  default = "ekssecureworkloads"
}
```

Apply the configuration and capture the outputs for later steps:

```bash
cd terraform/auto-mode
terraform init
terraform apply -var="region=us-west-2"

AWS_REGION="us-west-2"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
SIGNER_PROFILE_NAME="ekssecureworkloads"
SIGNER_PROFILE_ARN=$(terraform output -raw signing_profile_arn)
REPO_NAME="secure-demo"
REPO_URL="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${REPO_NAME}"
```

⚠️ Caution: Signer issues certificates automatically when you omit `--signing-material`. Bring your own certificate only if your PKI team manages issuance and rotation outside Signer.

Update the GitHub Actions role you created in the OIDC primer by attaching a scoped permissions policy that covers ECR push and AWS Signer access:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRPushAndList",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:CompleteLayerUpload",
        "ecr:CreateRepository",
        "ecr:DescribeImages",
        "ecr:DescribeRepositories",
        "ecr:GetAuthorizationToken",
        "ecr:GetDownloadUrlForLayer",
        "ecr:InitiateLayerUpload",
        "ecr:PutImage",
        "ecr:UploadLayerPart"
      ],
      "Resource": "arn:aws:ecr:us-west-2:123456789012:repository/secure-demo"
    },
    {
      "Sid": "SignerPermissions",
      "Effect": "Allow",
      "Action": [
        "signer:StartSigningJob",
        "signer:GetSigningProfile",
        "signer:DescribeSigningJob"
      ],
      "Resource": [
        "arn:aws:signer:us-west-2:123456789012:/signing-profiles/$SIGNER_PROFILE_NAME",
        "arn:aws:signer:us-west-2:123456789012:signing-jobs/*"
      ]
    }
  ]
}
```

💡 Tip: Add a second inline policy that allows `logs:CreateLogStream` and `logs:PutLogEvents` if you enable Signer logging to CloudWatch.

The trust policy that enables `sts:AssumeRoleWithWebIdentity` stays identical to the walkthrough in the [GitHub Actions OIDC guide](./stop-using-access-keys-github-actions-aws.md); you only need to extend the permissions above so the workflow can call Signer.

### 2. Configure Notation CLI for Local Signing

Install the Notation CLI v2.0.0 or newer following the <a href="https://notaryproject.dev/docs/user-guides/installation/cli/" target="_blank" rel="noreferrer">official installation guide</a>. Then build and install the AWS Signer Notation plugin v1.0.2292 from source. First, ensure Go is installed (<a href="https://go.dev/dl/" target="_blank" rel="noopener">download from go.dev</a> if needed):

```bash
# Verify Go is installed and in PATH
go version

# Download and extract the source code
curl -Lo notation-aws-signer.tar.gz https://github.com/aws/aws-signer-notation-plugin/archive/refs/tags/v1.0.2292.tar.gz
tar -xzf notation-aws-signer.tar.gz
cd aws-signer-notation-plugin-1.0.2292

# Build the plugin (this generates mocks and compiles the binary)
make build

# Install the built plugin
notation plugin install --file build/bin/notation-com.amazonaws.signer.notation.plugin

# Return to your working directory
cd ..

# Register Signer as a key provider (use the full ARN from Terraform output)
notation key add \
  --plugin com.amazonaws.signer.notation.plugin \
  --id "$SIGNER_PROFILE_ARN" \
  my-aws-signer-key
```

💡 Tip: If `make build` fails with a `mockgen: command not found` error, install the mock generator first: `go install github.com/golang/mock/mockgen@latest`. Then add the Go bin directory to your PATH: `export PATH=$PATH:$(go env GOPATH)/bin`. For persistence, add this line to your shell profile (`~/.zshrc` or `~/.bashrc`). This dynamically finds the Go bin directory regardless of your GOPATH configuration.

If you open a new terminal, re-export the values captured from Terraform so the next steps know which repository and profile to trust:

```bash
AWS_REGION="us-west-2"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
SIGNER_PROFILE_NAME="ekssecureworkloads"
SIGNER_PROFILE_ARN=$(cd terraform/auto-mode && terraform output -raw signing_profile_arn)
REPO_NAME="secure-demo"
REPO_URL="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${REPO_NAME}"
```

Before creating the trust policy, you must add the AWS Signer root certificate to a trust store. Download and add it:

```bash
# Download the AWS Signer root certificate
curl -o aws-signer-notation-root.cert https://d2hvyiie56hcat.cloudfront.net/aws-signer-notation-root.cert

# Add the certificate to the trust store (creates the trust store if it doesn't exist)
notation cert add --type signingAuthority --store aws-signer-ts aws-signer-notation-root.cert

# Verify the certificate was added
notation cert list
```

Create a trust policy JSON so Notation only trusts images from your ECR registry that are signed by the expected profile. Save it as `aws-signer-trust-policy.json`:

```json
{
  "version": "1.0",
  "trustPolicies": [
    {
      "name": "aws-signer-trust",
      "registryScopes": [
        "$REPO_URL"
      ],
      "signatureVerification": {
        "level": "strict"
      },
      "trustStores": [
        "signingAuthority:aws-signer-ts"
      ],
      "trustedIdentities": [
        "$SIGNER_PROFILE_ARN"
      ]
    }
  ]
}
```

Import the policy:

```bash
notation policy import aws-signer-trust-policy.json
notation policy show
```

Authenticate Docker to ECR and sign a sample image locally before you automate it:

```bash
SOURCE_IMAGE="public.ecr.aws/docker/library/alpine:3.19"
IMAGE_TAG="demo"

aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

docker pull "$SOURCE_IMAGE"
docker tag "$SOURCE_IMAGE" "$REPO_URL:$IMAGE_TAG"
docker push "$REPO_URL:$IMAGE_TAG"

notation sign --key my-aws-signer-key "$REPO_URL:$IMAGE_TAG"
notation verify "$REPO_URL:$IMAGE_TAG"
```

✅ Result: You should see `Successfully signed` and `Successfully verified` output. Store the resulting signature artifact in AWS Signer; you can inspect it with `aws signer list-signing-jobs` for auditing.

### 3. Automate Signing in CI (Reference Playbook)

Once your local workflow is dialed in, hand it off to CI so every build is signed. Create `.github/workflows/build-sign-push.yml` in your repository:

```yaml
name: Build, Sign, and Push Container

on:
  push:
    branches: ["main"]
  workflow_dispatch:

permissions:
  contents: read
  id-token: write
  packages: write

jobs:
  build-sign-push:
    runs-on: ubuntu-latest
    env:
      AWS_REGION: us-west-2
      ECR_REPOSITORY: secure-demo
      SIGNER_PROFILE_NAME: ekssecureworkloads
      NOTATION_VERSION: 2.0.0-alpha.1
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Configure AWS credentials
        id: configure-aws-credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume:  ${{ secrets.AWS_ROLE_TO_ASSUME }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Login to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Set up Go
        uses: actions/setup-go@v5
        with:
          go-version: 'stable'

      - name: Set up Notation CLI
        run: |
          curl -LO https://github.com/notaryproject/notation/releases/download/v${NOTATION_VERSION}/notation_${NOTATION_VERSION}_linux_amd64.tar.gz
          tar xvzf notation_${NOTATION_VERSION}_linux_amd64.tar.gz notation
          sudo mv notation /usr/local/bin/

      - name: Build and install AWS Signer Notation plugin
        run: |
          go version
          
          # Download and extract the source code
          curl -Lo notation-aws-signer.tar.gz https://github.com/aws/aws-signer-notation-plugin/archive/refs/tags/v1.0.2292.tar.gz
          tar -xzf notation-aws-signer.tar.gz
          cd aws-signer-notation-plugin-1.0.2292
          
          # Build the plugin (this generates mocks and compiles the binary)
          make build
          
          # Install the built plugin
          notation plugin install --file build/bin/notation-com.amazonaws.signer.notation.plugin
          
          # Return to working directory
          cd ..
          
          # Add the signing key
          notation key add \
            --plugin com.amazonaws.signer.notation.plugin \
            --id "arn:aws:signer:${{ env.AWS_REGION }}:${{ steps.configure-aws-credentials.outputs.aws-account-id }}:/signing-profiles/${{ env.SIGNER_PROFILE_NAME }}" \
            my-aws-signer-key || true

      - name: Add AWS Signer root certificate to trust store
        run: |
          curl -o aws-signer-notation-root.cert https://d2hvyiie56hcat.cloudfront.net/aws-signer-notation-root.cert
          notation cert add --type signingAuthority --store aws-signer-ts aws-signer-notation-root.cert
          # Verify certificate was added
          notation cert ls --type signingAuthority --store aws-signer-ts

      - name: Configure Notation trust policy
        run: |
          echo '{
            "version": "1.0",
            "trustPolicies": [
              {
                "name": "aws-signer-trust",
                "registryScopes": [
                  "${{ steps.login-ecr.outputs.registry }}/${{ env.ECR_REPOSITORY }}"
                ],
                "signatureVerification": {
                  "level": "strict"
                },
                "trustStores": [
                  "signingAuthority:aws-signer-ts"
                ],
                "trustedIdentities": [
                  "arn:aws:signer:${{ env.AWS_REGION }}:${{ steps.configure-aws-credentials.outputs.aws-account-id }}:/signing-profiles/${{ env.SIGNER_PROFILE_NAME }}"
                ]
              }
            ]
          }' > aws-signer-trust-policy.json
          cat aws-signer-trust-policy.json
          notation policy import --force aws-signer-trust-policy.json
          # Verify policy was imported
          notation policy show

      - name: Pull, tag, and push image
        env:
          SOURCE_IMAGE: public.ecr.aws/docker/library/nginx:latest
          IMAGE_TAG: ${{ github.sha }}
          REPO_URL: ${{ steps.login-ecr.outputs.registry }}/${{ env.ECR_REPOSITORY }}
        run: |
          docker pull "$SOURCE_IMAGE"
          docker tag "$SOURCE_IMAGE" "$REPO_URL:$IMAGE_TAG"
          # Push and capture the digest from push output
          PUSH_OUTPUT=$(docker push "$REPO_URL:$IMAGE_TAG" 2>&1)
          echo "$PUSH_OUTPUT"
          # Extract digest from push output (format: digest: sha256:...)
          IMAGE_DIGEST=$(echo "$PUSH_OUTPUT" | grep -o 'sha256:[a-f0-9]\{64\}' | head -1 | cut -d':' -f2)
          if [ -z "$IMAGE_DIGEST" ]; then
            # Fallback: use docker manifest inspect
            IMAGE_DIGEST=$(docker manifest inspect "$REPO_URL:$IMAGE_TAG" 2>/dev/null | grep '"digest"' | head -1 | grep -o 'sha256:[a-f0-9]\{64\}' | cut -d':' -f2)
          fi
          if [ -z "$IMAGE_DIGEST" ]; then
            echo "Error: Could not extract image digest"
            exit 1
          fi
          echo "IMAGE_DIGEST=$IMAGE_DIGEST" >> $GITHUB_ENV
          echo "Image digest: $IMAGE_DIGEST"

      - name: Configure Notation for ECR authentication
        run: |
          # Configure Notation to use Docker credential store
          mkdir -p ~/.config/notation
          
          cat > ~/.config/notation/config.json <<EOF
          {
            "credentialHelpers": {
              "${{ steps.login-ecr.outputs.registry }}": "docker"
            }
          }
          EOF

      - name: Sign image with AWS Signer via Notation
        env:
          REPO_URL: ${{ steps.login-ecr.outputs.registry }}/${{ env.ECR_REPOSITORY }}
        run: |
          # Construct the full image digest reference
          IMAGE_DIGEST="$REPO_URL@sha256:$IMAGE_DIGEST"
          echo "Signing image with digest: $IMAGE_DIGEST"
          
          # Sign using the digest directly
          notation sign --key my-aws-signer-key "$IMAGE_DIGEST"
          
          # Wait for signature to propagate in ECR
          echo "Waiting for signature to propagate..."
          sleep 5
          
          # Verify using the digest with verbose output
          echo "Verifying signature for: $IMAGE_DIGEST"
          notation verify --verbose "$IMAGE_DIGEST" || {
            echo "Verification failed, checking if signature exists..."
            notation list "$IMAGE_DIGEST" || true
            exit 1
          }

      - name: Upload build metadata
        if: always()
        env:
          REPO_URL: ${{ steps.login-ecr.outputs.registry }}/${{ env.ECR_REPOSITORY }}
        run: |
          if [ -n "$IMAGE_DIGEST" ]; then
            IMAGE_DIGEST_REF="$REPO_URL@sha256:$IMAGE_DIGEST"
            echo "Listing signatures for: $IMAGE_DIGEST_REF"
            notation list "$IMAGE_DIGEST_REF" || echo "No signatures found or error listing signatures"
          else
            echo "IMAGE_DIGEST not available, skipping signature listing"
          fi
```

Use the same OIDC trust relationship from the [GitHub Actions OIDC guide](./stop-using-access-keys-github-actions-aws.md) so the workflow can assume the role configured earlier.

⚠️ Caution: Keep your repository and branch conditions tight in that trust policy so forks cannot assume the role that signs production images.

### 4. Prepare Your Auto Mode EKS Cluster

With the Terraform stack applied, verify the cluster is healthy and refresh your `kubeconfig` so kubectl can reach it:

```bash
AWS_REGION=us-west-2
CLUSTER_NAME=auto-mode-lab

aws eks update-kubeconfig \
  --region "$AWS_REGION" \
  --name "$CLUSTER_NAME"

kubectl get nodes
```

✅ Result: You should see the Auto Mode-managed node groups ready. Proceed only after confirming you can schedule workloads.

### 5. Deploy Ratify and Gatekeeper with Terraform

You will install Gatekeeper, Ratify, their trust policy, and all admission resources directly through Terraform so every environment stays reproducible. Add `gatekeeper-ratify.tf` to the project. Start by configuring EKS Pod Identity so Ratify can read from private ECR repositories and check revocation status in AWS Signer without long-lived credentials. For a deeper dive into Pod Identity, see the [EKS Pod Identity Terraform playbook](./eks-pod-identity-terraform-playbook.md):

```hcl
data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

data "aws_eks_cluster_auth" "this" {
  name = var.cluster_name
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "ratify_signer_permissions" {
  statement {
    sid     = "SignerRevocation"
    actions = ["signer:GetRevocationStatus"]
    effect  = "Allow"
    resources = [
      aws_signer_signing_profile.eks_secure.arn,
      "arn:aws:signer:${var.region}:${data.aws_caller_identity.current.account_id}:signing-jobs/*"
    ]
  }
}

resource "aws_iam_role" "ratify" {
  name = "${var.cluster_name}-ratify"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ratify_ecr" {
  role       = aws_iam_role.ratify.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy" "ratify_signer" {
  role   = aws_iam_role.ratify.id
  policy = data.aws_iam_policy_document.ratify_signer_permissions.json
}

resource "kubernetes_namespace" "gatekeeper_system" {
  metadata {
    name = "gatekeeper-system"
  }
}

resource "aws_eks_pod_identity_association" "ratify" {
  cluster_name    = var.cluster_name
  namespace       = "gatekeeper-system"
  service_account = "ratify-admin"
  role_arn        = aws_iam_role.ratify.arn

  depends_on = [kubernetes_namespace.gatekeeper_system]
}

resource "kubernetes_service_account" "ratify" {
  metadata {
    name      = "ratify-admin"
    namespace = kubernetes_namespace.gatekeeper_system.metadata[0].name
  }

  depends_on = [kubernetes_namespace.gatekeeper_system]
}
```

💡 Tip: EKS Pod Identity eliminates the need for OIDC provider configuration and service account annotations. The Pod Identity agent is pre-installed on EKS Auto Mode clusters, so the association works immediately after Terraform applies. Learn more about Pod Identity setup and migration from IRSA in the [EKS Pod Identity Terraform playbook](./eks-pod-identity-terraform-playbook.md).

Next, install Gatekeeper and Ratify using Helm. Gatekeeper provides the admission webhook framework, and Ratify handles signature verification. Configure Ratify's Notation verifier with your AWS Signer trust policy through Helm values. Enable Gatekeeper's external data provider so it can query Ratify during admission decisions.

After the Helm releases are deployed and CRDs are registered, use Terraform `null_resource` resources with `kubectl apply` to create the Gatekeeper constraint template, constraint, AWS Signer dynamic plugin, and Notation verifier configuration. We use `null_resource` instead of `kubernetes_manifest` to avoid Terraform's CRD validation during plan, which can fail before CRDs are fully registered. The wait resources ensure CRDs are available before applying manifests:

```hcl
# ==============================================================================
# Gatekeeper + Ratify with AWS Signer Integration
# ==============================================================================
# This configuration deploys Gatekeeper and Ratify to verify container image
# signatures using AWS Signer. Key AWS Signer-specific requirements:
#
# 1. IAM Policy: Must include leading "/" in signing-jobs ARN:
#    arn:aws:signer:REGION:ACCOUNT:/signing-jobs/* (note the colon-slash)
#
# 2. Trust Store Type: AWS Signer requires "signingAuthority" type, not "ca":
#    verificationCertStores:
#      signingAuthority:
#        certs: [...]
#    trustStores:
#      - signingAuthority:certs
#
# 3. Certificate: AWS Signer root certificate required for signature validation
# ==============================================================================

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

data "aws_eks_cluster_auth" "this" {
  name = var.cluster_name
}

data "aws_caller_identity" "current" {}

# Get OIDC provider - construct ARN from cluster OIDC issuer
locals {
  oidc_provider_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(data.aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")}"
  oidc_provider_url = replace(data.aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
}

# IAM policy for Ratify to check AWS Signer revocation status
# IMPORTANT: ARN must include leading "/" before "signing-jobs"
data "aws_iam_policy_document" "ratify_signer_permissions" {
  statement {
    sid     = "SignerRevocation"
    actions = ["signer:GetRevocationStatus"]
    effect  = "Allow"
    resources = [
      aws_signer_signing_profile.eks_secure.arn,
      "arn:aws:signer:${var.region}:${data.aws_caller_identity.current.account_id}:/signing-jobs/*"
    ]
  }
}

resource "aws_iam_role" "ratify" {
  name = "${var.cluster_name}-ratify"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = local.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.oidc_provider_url}:sub" = "system:serviceaccount:gatekeeper-system:ratify-admin"
            "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ratify_ecr" {
  role       = aws_iam_role.ratify.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy" "ratify_signer" {
  role   = aws_iam_role.ratify.id
  policy = data.aws_iam_policy_document.ratify_signer_permissions.json
}

resource "kubernetes_namespace" "gatekeeper_system" {
  metadata {
    name = "gatekeeper-system"
  }
}

resource "kubernetes_service_account" "ratify" {
  metadata {
    name      = "ratify-admin"
    namespace = kubernetes_namespace.gatekeeper_system.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.ratify.arn
    }
  }

  depends_on = [kubernetes_namespace.gatekeeper_system]
}


provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

resource "helm_release" "gatekeeper" {
  name       = "gatekeeper"
  namespace  = kubernetes_namespace.gatekeeper_system.metadata[0].name
  repository = "https://open-policy-agent.github.io/gatekeeper/charts"
  chart      = "gatekeeper"

  depends_on = [kubernetes_namespace.gatekeeper_system]

  set {
    name  = "enableExternalData"
    value = "true"
  }

  set {
    name  = "validatingWebhookTimeoutSeconds"
    value = "5"
  }

  set {
    name  = "mutatingWebhookTimeoutSeconds"
    value = "10"
  }

  set {
    name  = "externaldataProviderResponseCacheTTL"
    value = "0s"
  }
}

resource "helm_release" "ratify" {
  name       = "ratify"
  namespace  = kubernetes_namespace.gatekeeper_system.metadata[0].name
  repository = "https://notaryproject.github.io/ratify"
  chart      = "ratify"

  depends_on = [
    kubernetes_namespace.gatekeeper_system,
    kubernetes_service_account.ratify,
    aws_iam_role_policy_attachment.ratify_ecr,
    aws_iam_role_policy.ratify_signer
  ]

  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = kubernetes_service_account.ratify.metadata[0].name
  }

  values = [
    yamlencode({
      # AWS Signer root certificate for signature validation
      notationCerts = [
        file("${path.module}/files/aws-signer-notation-root.cert")
      ]
      # Explicit AWS environment variables for IRSA authentication
      extraEnv = [
        {
          name  = "AWS_REGION"
          value = var.region
        },
        {
          name  = "AWS_ROLE_ARN"
          value = aws_iam_role.ratify.arn
        },
        {
          name  = "AWS_WEB_IDENTITY_TOKEN_FILE"
          value = "/var/run/secrets/eks.amazonaws.com/serviceaccount/token"
        }
      ]
    })
  ]
  set {
    name  = "notation.enabled"
    value = "true"
  }
  set {
    name  = "featureFlags.RATIFY_EXPERIMENTAL_DYNAMIC_PLUGINS"
    value = "true"
  }

  set {
    name  = "featureFlags.RATIFY_CERT_ROTATION"
    value = "true"
  }
  set {
    name  = "oras.authProviders.awsEcrBasicEnabled"
    value = "true"
  }
}

# Note: While IRSA automatically injects AWS_ROLE_ARN and AWS_WEB_IDENTITY_TOKEN_FILE,
# we explicitly set them above (lines 181-186) for clarity and to ensure proper values.
# AWS_REGION must be set explicitly as IRSA doesn't provide it.
# IRSA is used instead of EKS Pod Identity because Ratify's ECR auth provider specifically
# requires the AWS_WEB_IDENTITY_TOKEN_FILE environment variable for authentication.

# Wait for Gatekeeper CRDs to be available
resource "null_resource" "wait_for_gatekeeper_crds" {
  depends_on = [helm_release.gatekeeper]

  provisioner "local-exec" {
    command = <<-EOT
      for i in {1..30}; do
        if kubectl get crd constrainttemplates.templates.gatekeeper.sh 2>/dev/null; then
          echo "Gatekeeper CRDs are ready"
          exit 0
        fi
        echo "Waiting for Gatekeeper CRDs... ($i/30)"
        sleep 2
      done
      echo "Timeout waiting for Gatekeeper CRDs"
      exit 1
    EOT
  }

  triggers = {
    gatekeeper_release = helm_release.gatekeeper.id
  }
}

# Wait for Ratify CRDs to be available
resource "null_resource" "wait_for_ratify_crds" {
  depends_on = [helm_release.ratify]

  provisioner "local-exec" {
    command = <<-EOT
      for i in {1..30}; do
        if kubectl get crd verifiers.config.ratify.deislabs.io 2>/dev/null; then
          echo "Ratify CRDs are ready"
          exit 0
        fi
        echo "Waiting for Ratify CRDs... ($i/30)"
        sleep 2
      done
      echo "Timeout waiting for Ratify CRDs"
      exit 1
    EOT
  }

  triggers = {
    ratify_release = helm_release.ratify.id
  }
}

resource "null_resource" "ratify_gatekeeper_template" {
  depends_on = [null_resource.wait_for_gatekeeper_crds]

  provisioner "local-exec" {
    command = <<-EOT
      kubectl apply -f - <<YAML
apiVersion: templates.gatekeeper.sh/v1beta1
kind: ConstraintTemplate
metadata:
  name: ratifyverification
spec:
  crd:
    spec:
      names:
        kind: RatifyVerification
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package ratifyverification

        # Get data from Ratify
        remote_data := response {
          images := [img | img = input.review.object.spec.containers[_].image]
          images_init := [img | img = input.review.object.spec.initContainers[_].image]
          images_ephemeral := [img | img = input.review.object.spec.ephemeralContainers[_].image]
          other_images := array.concat(images_init, images_ephemeral)
          all_images := array.concat(other_images, images)
          response := external_data({"provider": "ratify-provider", "keys": all_images})
        }

        # Base Gatekeeper violation
        violation[{"msg": msg}] {
          general_violation[{"result": msg}]
        }

        # Check if there are any system errors
        general_violation[{"result": result}] {
          err := remote_data.system_error
          err != ""
          result := sprintf("System error calling external data provider: %s", [err])
        }

        # Check if there are errors for any of the images
        general_violation[{"result": result}] {
          count(remote_data.errors) > 0
          result := sprintf("Error validating one or more images: %s", remote_data.errors)
        }

        # Check if the success criteria is true
        general_violation[{"result": result}] {
          subject_validation := remote_data.responses[_]
          subject_validation[1].isSuccess == false
          result := sprintf("Artifact failed verification: %s, \nreport: %v", [subject_validation[0], subject_validation[1]])
        }
YAML
    EOT
  }

  triggers = {
    gatekeeper_crds = null_resource.wait_for_gatekeeper_crds.id
  }
}

resource "null_resource" "ratify_gatekeeper_constraint" {
  depends_on = [null_resource.ratify_gatekeeper_template]

  provisioner "local-exec" {
    command = <<-EOT
      kubectl apply -f - <<YAML
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: RatifyVerification
metadata:
  name: ratify-constraint
spec:
  enforcementAction: deny
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    namespaces: ["default"]
YAML
    EOT
  }

  triggers = {
    template = null_resource.ratify_gatekeeper_template.id
  }
}

resource "null_resource" "ratify_aws_signer_plugin" {
  depends_on = [null_resource.wait_for_ratify_crds]

  provisioner "local-exec" {
    command = <<-EOT
      kubectl apply -f - <<YAML
apiVersion: config.ratify.deislabs.io/v1beta1
kind: Verifier
metadata:
  name: aws-signer-plugin
  namespace: gatekeeper-system
spec:
  name: notation-com.amazonaws.signer.notation.plugin
  artifactTypes: application/vnd.oci.image.manifest.v1+json
  source:
    artifact: public.ecr.aws/aws-signer/notation-plugin:linux-amd64-latest
YAML
    EOT
  }

  triggers = {
    ratify_crds = null_resource.wait_for_ratify_crds.id
  }
}

resource "null_resource" "ratify_certificate_store" {
  depends_on = [null_resource.wait_for_ratify_crds]

  provisioner "local-exec" {
    command = <<-EOT
      # Create CertificateStore CRD with AWS Signer root certificate
      kubectl apply -f - <<YAML
apiVersion: config.ratify.deislabs.io/v1beta1
kind: CertificateStore
metadata:
  name: ratify-notation-inline-cert-0
  namespace: gatekeeper-system
spec:
  provider: inline
  parameters:
    value: |
$(cat ${path.module}/files/aws-signer-notation-root.cert | sed 's/^/      /')
YAML
    EOT
  }

  triggers = {
    ratify_crds = null_resource.wait_for_ratify_crds.id
    cert_file   = filemd5("${path.module}/files/aws-signer-notation-root.cert")
  }
}

resource "null_resource" "ratify_notation_verifier" {
  depends_on = [
    null_resource.wait_for_ratify_crds,
    null_resource.ratify_aws_signer_plugin,
    null_resource.ratify_certificate_store,
    helm_release.ratify
  ]

  provisioner "local-exec" {
    environment = {
      SIGNER_PROFILE_ARN = aws_signer_signing_profile.eks_secure.arn
    }
    command = <<-EOT
      # Apply the Verifier with AWS Signer trust policy configuration
      # Uses signingAuthority trust store type (required for AWS Signer)
      kubectl apply -f - <<YAML
apiVersion: config.ratify.deislabs.io/v1beta1
kind: Verifier
metadata:
  name: verifier-notation
  namespace: gatekeeper-system
spec:
  name: notation
  artifactTypes: application/vnd.cncf.notary.signature
  parameters:
    verificationCertStores:
      signingAuthority:
        certs:
          - ratify-notation-inline-cert-0
    trustPolicyDoc:
      version: "1.0"
      trustPolicies:
        - name: default
          registryScopes:
            - "*"
          signatureVerification:
            level: strict
          trustStores:
            - signingAuthority:certs
          trustedIdentities:
            - $SIGNER_PROFILE_ARN
YAML
    EOT
  }

  triggers = {
    ratify_crds         = null_resource.wait_for_ratify_crds.id
    aws_signer_plugin   = null_resource.ratify_aws_signer_plugin.id
    signing_profile_arn = aws_signer_signing_profile.eks_secure.arn
    certificate_store   = null_resource.ratify_certificate_store.id
    helm_release        = helm_release.ratify.id
    # Hash of the verifier config to detect trust policy changes
    verifier_config_hash = md5(jsonencode({
      trust_store_type   = "signingAuthority:certs"
      verification_level = "strict"
      registry_scopes    = ["*"]
    }))
  }
}

```

Create `files/aws-signer-notation-root.cert` next to your Terraform so Helm can mount the AWS Signer root certificate. This is the same PEM that AWS publishes at <a href="https://d2hvyiie56hcat.cloudfront.net/aws-signer-notation-root.cert" target="_blank" rel="noopener">d2hvyiie56hcat.cloudfront.net/aws-signer-notation-root.cert</a>:

```text
-----BEGIN CERTIFICATE-----
MIICWTCCAd6gAwIBAgIRAMq5Lmt4rqnUdi8qM4eIGbYwCgYIKoZIzj0EAwMwbDEL
MAkGA1UEBhMCVVMxDDAKBgNVBAoMA0FXUzEVMBMGA1UECwwMQ3J5cHRvZ3JhcGh5
MQswCQYDVQQIDAJXQTErMCkGA1UEAwwiQVdTIFNpZ25lciBDb2RlIFNpZ25pbmcg
Um9vdCBDQSBHMTAgFw0yMjEwMjcyMTMzMjJaGA8yMTIyMTAyNzIyMzMyMlowbDEL
MAkGA1UEBhMCVVMxDDAKBgNVBAoMA0FXUzEVMBMGA1UECwwMQ3J5cHRvZ3JhcGh5
MQswCQYDVQQIDAJXQTErMCkGA1UEAwwiQVdTIFNpZ25lciBDb2RlIFNpZ25pbmcg
Um9vdCBDQSBHMTB2MBAGByqGSM49AgEGBSuBBAAiA2IABM9+dM9WXbVyNOIP08oN
IQW8DKKdBxP5nYNegFPLfGP0f7+0jweP8LUv1vlFZqVDep5ONus9IxwtIYBJLd36
5Q3Z44Xnm4PY/wSI5xRvB/m+/B2PHc7Smh0P5s3Dt25oVKNCMEAwDwYDVR0TAQH/
BAUwAwEB/zAdBgNVHQ4EFgQUONhd3abPX87l4YWKxjysv28QwAYwDgYDVR0PAQH/
BAQDAgGGMAoGCCqGSM49BAMDA2kAMGYCMQCd32GnYU2qFCtKjZiveGfs+gCBlPi2
Hw0zU52LXIFC2GlcvwcekbiM6w0Azlr9qvMCMQDl4+Os0yd+fVlYMuovvxh8xpjQ
NPJ9zRGyYa7+GNs64ty/Z6bzPHOKbGo4In3KKJo=
-----END CERTIFICATE-----
```

Now re-run Terraform so Helm rolls out Gatekeeper and Ratify while the `kubernetes_manifest` resources layer on the constraint template, constraint, AWS Signer dynamic plugin, and Notation verifier. Managing everything in Terraform keeps the workflow idempotent and version-controlled:

```bash
terraform apply -var="region=us-west-2"

kubectl -n gatekeeper-system get sa ratify-admin -oyaml

aws eks list-pod-identity-associations \
  --cluster-name $CLUSTER_NAME \
  --namespace gatekeeper-system

kubectl get pods -n gatekeeper-system
```

✅ Result: You should see the `ratify-admin` service account with the pod identity association active plus Gatekeeper and Ratify pods in the `gatekeeper-system` namespace. Verify the association with `aws eks list-pod-identity-associations --cluster-name $CLUSTER_NAME` to confirm the role binding. 

The Terraform-managed manifests push the same Gatekeeper policy and Notation resources you would apply manually, so unsigned images are denied out of the box. Everything tears down cleanly through `terraform destroy` when you are done.

### 6. Validate Enforcement

First, attempt to deploy an unsigned image. Create a simple manifest:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: unsigned-app
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: unsigned-app
  template:
    metadata:
      labels:
        app: unsigned-app
    spec:
      containers:
        - name: unsigned
          image: public.ecr.aws/docker/library/nginx:latest
```

Apply and inspect the result:

```bash
kubectl apply -f unsigned-deploy.yaml
kubectl get deploy unsigned-app -n default
kubectl describe deploy unsigned-app -n default
```

Gatekeeper stores the deployment object, but the admission webhook denies every replica so pods never start. To watch the rejection directly, try launching a throwaway pod:

```bash
kubectl run unsigned-test \
  --image=public.ecr.aws/docker/library/nginx:latest \
  --restart=Never
```

You should see a webhook deny message explaining that the image lacks a trusted Notation signature.

Now deploy the signed image emitted by your pipeline. Replace `{{GITHUB_SHA}}` with the digest or tag you signed in the previous step:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: signed-app
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: signed-app
  template:
    metadata:
      labels:
        app: signed-app
    spec:
      containers:
        - name: signed
          image: ${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/secure-demo:{{GITHUB_SHA}}
```

Render the manifest with the environment variables you exported earlier—for example:

```bash
envsubst < signed-deploy.yaml > signed-deploy-rendered.yaml
kubectl apply -f signed-deploy-rendered.yaml
kubectl get pods -n default -l app=signed-app
kubectl logs deploy/signed-app -n default
```

✅ Result: The signed deployment should roll out normally. Ratify pins the digest in the admission review so only the verified artifact runs.

## Cleanup

1. Delete test workloads:

```bash
kubectl delete deployment unsigned-app signed-app -n default --ignore-not-found
kubectl delete pod unsigned-test -n default --ignore-not-found
```

2. Remove the Gatekeeper policy objects you applied from the Ratify repository:

```bash
kubectl delete -f https://raw.githubusercontent.com/notaryproject/ratify/main/configs/constrainttemplates/default/constraint.yaml --ignore-not-found
kubectl delete -f https://raw.githubusercontent.com/notaryproject/ratify/main/configs/constrainttemplates/default/template.yaml --ignore-not-found
```

3. Remove the Helm releases with Terraform when you are finished validating:

```bash
terraform destroy \
  -target=helm_release.ratify \
  -target=helm_release.gatekeeper
```

4. Tear down the EKS cluster, ECR repository, Signer profile, and pod identity associations through the same Terraform stack once you are done experimenting:

```bash
terraform destroy -var="region=us-west-2"
```

This automatically removes the pod identity association, IAM role, and all related resources.

5. Disable the GitHub Actions IAM role or narrow its trust policy after testing.

⚠️ Caution: Destroying the EKS cluster will remove the node compute charges. ECR storage and CloudWatch logs can persist and incur small costs until deleted.

## Key Takeaways

1. AWS Signer plus Notation gives you a managed certificate chain without running your own signing infrastructure.
2. GitHub Actions with OIDC keeps the software supply chain secretless; no long-lived keys are necessary.
3. Ratify with Gatekeeper enforces integrity at admission so compromised tags are rejected automatically.
4. Observability matters—ship Signer job events to CloudWatch or EventBridge to alert on failures.
5. Clean up Signer profiles, IAM roles, and Ratify constraints when unused to limit blast radius and costs.

### Related Reading

- Learn how to configure EKS Pod Identity with Terraform in the [EKS Pod Identity Terraform playbook](./eks-pod-identity-terraform-playbook.md).
- Bootstrap an EKS Auto Mode cluster quickly with [EKS Auto Mode Quick Bootstrap with Terraform](./eks-auto-mode-quick-bootstrap-terraform.md).
- Secure GitHub Actions runners without keys using [Stop Managing GitHub Actions Access Keys for AWS](./stop-using-access-keys-github-actions-aws.md).

For more software supply chain hardening, explore Ratify's policy tuning and monitor `signer.amazonaws.com` usage in CloudTrail. External references like the <a href="https://docs.aws.amazon.com/signer/latest/developerguide/Welcome.html" target="_blank" rel="noopener">AWS Signer documentation</a>, <a href="https://github.com/deislabs/ratify" target="_blank" rel="noopener">Ratify project</a>, and <a href="https://open-policy-agent.github.io/gatekeeper/website/docs/" target="_blank" rel="noopener">Gatekeeper docs</a> include deeper production considerations.
