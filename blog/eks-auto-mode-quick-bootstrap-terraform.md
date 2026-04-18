
## Why this EKS Auto Mode Terraform lab matters

Amazon EKS Auto Mode finally lets you launch a Kubernetes control plane and managed worker capacity withoucet juggling node groups, but getting a clean environment still takes real work. The public docs scatter the Terraform pieces, and it’s easy to miss IAM or cleanup steps that keep this under the promised $5. Today you’ll build an **eks auto mode terraform** lab that spins up fast, ships a workload, and tears down without surprises.

We’ll use Terraform 1.13.5, the AWS provider, and a minimal IAM role to stand up the cluster in `us-west-2`. You’ll push a simple HTTP deployment, hit it with `kubectl`, and confirm Auto Mode created the on-demand worker capacity for you.

## What You’ll Build

By the end of this playbook you’ll have a disposable VPC, an EKS Auto Mode cluster, and a sample pod responding to HTTP traffic. Auto Mode handles compute provisioning, so you never touch managed node groups or Karpenter. Terraform keeps everything codified and ready to destroy once you’re done validating.

```
Developer laptop
    │
    ├─ Terraform CLI ─► AWS APIs (IAM, VPC, EKS)
    │                    │
    │                    └─ EKS Auto Mode control plane & compute
    │                                 │
    └─ kubectl ─► Sample Deployment → Auto-managed nodes
```

| Component | Purpose |
|-----------|---------|
| Terraform | Provision the VPC, IAM, and EKS Auto Mode cluster |
| AWS IAM role | Grant Terraform least-privilege access to create resources |
| EKS Auto Mode | Manages Kubernetes control plane and serverless-like data plane |
| Test workload | Validates scheduling on the Auto Mode managed capacity |

## Prerequisites

- AWS account with a clean sandbox in **us-west-2**.
- CLI stack: Terraform **1.6 or newer**, AWS CLI v2, kubectl 1.34+, Docker 24+, and jq.
- An IAM role or user that can create IAM roles/policies, VPC resources, and EKS clusters (attach `AdministratorAccess` in a sandbox, or compose the JSON policy in the IAM notes below).
- Local credentials exported via `AWS_PROFILE` or environment variables; avoid long-lived CI keys and prefer AWS SSO or IAM Identity Center.
- Budget: this cluster plus NAT Gateway will stay under **$5** for a few hours. Shut everything down after testing.

## Step-by-Step Playbook

### 1. Clone or initialize the working directory

Create an empty directory and initialize your Terraform module:

```bash
mkdir -p ~/eks-auto-mode-terraform && cd ~/eks-auto-mode-terraform
```

### 2. Write Terraform configuration files

Create the following files. Each block includes comments that explain the Auto Mode specifics.

**`versions.tf`**

```hcl
terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "aws" {
  region = var.aws_region
}
```

**`locals.tf`**

```hcl
locals {
  name = var.cluster_name

  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Project     = local.name
    Environment = "lab"
    ManagedBy   = "terraform"
  }
}
```

**`data.tf`**

```hcl
data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}
```

**`variables.tf`**

```hcl
variable "aws_region" {
  description = "AWS region for the EKS Auto Mode lab"
  type        = string
  default     = "us-west-2"
}

variable "cluster_name" {
  description = "Name for the EKS cluster and supporting resources"
  type        = string
  default     = "auto-mode-lab"
}

variable "eks_cluster_version" {
  description = "Kubernetes version for EKS"
  type        = string
  default     = "1.34"
}

variable "vpc_cidr" {
  description = "CIDR for the lab VPC"
  type        = string
  default     = "10.20.0.0/16"
}
```

The `terraform-aws-modules/eks` module now manages the control plane IAM role by default, including the `AmazonEKSComputePolicy`
attachment required for Auto Mode. Keeping that default simplifies the lab, so there’s no need to create a separate
`cluster_iam_role` or set `cluster_iam_role_name`.

**`network.tf`**

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = [for index, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, index)]
  public_subnets  = [for index, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, index + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = local.tags
}
```

**`eks.tf`**

```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name    = local.name
  cluster_version = var.eks_cluster_version

  enable_cluster_creator_admin_permissions = true
  cluster_endpoint_public_access           = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_compute_config = {
    enabled    = true
    node_pools = ["general-purpose"]
  }

  tags = local.tags
}

```

**`outputs.tf`**

```hcl
output "cluster_name" {
  description = "Deployed EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "aws_region" {
  description = "Region where the cluster is deployed"
  value       = var.aws_region
}
```

💡 Tip: Auto Mode is controlled through the `cluster_compute_config` block. Set `enabled = true` and pick a managed node pool size such as `general-purpose` for on-demand compute.

⚠️ Caution: Turning Auto Mode off is a two-step Terraform sequence. First, change `cluster_compute_config` to `{ enabled = false }` and apply so AWS records the disablement. Second, remove the block entirely and apply again to keep future plans clean.

### 3. Note the IAM permissions Terraform needs

If you can’t use `AdministratorAccess`, attach a policy that covers EKS, VPC, IAM role creation, CloudWatch Logs, and EC2 networking primitives. Start with this scaffold and tighten it for production:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "eks:*",
        "ec2:*",
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:PassRole",
        "iam:CreatePolicy",
        "iam:DeletePolicy",
        "iam:GetPolicy",
        "iam:GetRole",
        "iam:ListAttachedRolePolicies",
        "cloudwatch:CreateLogGroup",
        "cloudwatch:DeleteLogGroup"
      ],
      "Resource": "*"
    }
  ]
}
```

⚠️ Caution: This policy is intentionally broad for a lab. Scope the `iam:*` and `ec2:*` actions to specific resources before using it in production.

### 4. Initialize and apply Terraform

```bash
terraform init
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

Expect the apply to run for ~15 minutes while Auto Mode provisions managed compute.

✅ Result: You should see outputs for the cluster name, API endpoint, and AWS region.

### 5. Configure kubectl and inspect the cluster

```bash
eks_cluster=$(terraform output -raw cluster_name)
aws eks update-kubeconfig \
  --region $(terraform output -raw aws_region 2>/dev/null || echo "us-west-2") \
  --name "$eks_cluster"

# test the connection
kubectl get nodes
kubectl get ns
```

💡 Tip: Auto Mode nodes show up as AWS-managed `fargate-like` instances. Give them a minute to register after the first workload schedules.

### 6. Deploy a test workload

Create a `manifests` directory and add a manifest that runs a tiny HTTP server and exposes it through a ClusterIP Service.

```bash
mkdir -p manifests
```

**`manifests/demo.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-auto-mode
  labels:
    app: hello-auto-mode
spec:
  replicas: 1
  selector:
    matchLabels:
      app: hello-auto-mode
  template:
    metadata:
      labels:
        app: hello-auto-mode
    spec:
      containers:
        - name: web
          image: public.ecr.aws/docker/library/nginx:1.25
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
          securityContext:
            allowPrivilegeEscalation: false
---
apiVersion: v1
kind: Service
metadata:
  name: hello-auto-mode
spec:
  type: ClusterIP
  selector:
    app: hello-auto-mode
  ports:
    - port: 80
      targetPort: 80
```

Apply and verify the workload:

```bash
kubectl apply -f manifests/demo.yaml
kubectl rollout status deployment/hello-auto-mode
kubectl get pods -l app=hello-auto-mode -o wide
```

### 7. Port-forward to test HTTP response

```bash
kubectl port-forward svc/hello-auto-mode 8080:80 >/tmp/port-forward.log &
sleep 3
curl -s http://127.0.0.1:8080/ | grep -i "Welcome to nginx"
kill %1
```

✅ Result: The HTML response confirms that Auto Mode scheduled the pod and the cluster is serving traffic.

### 8. Observability checks (optional but fast)

Use these quick commands to confirm Auto Mode compute activity:

```bash
kubectl describe node $(kubectl get nodes -o jsonpath='{.items[0].metadata.name}') | grep -iE "instance-type|capacity-type"
kubectl top pods -A
```

💡 Tip: Install `kubectl top` support by enabling the EKS managed metrics server add-on if you plan to keep the cluster longer.

## Cleanup

Destroy every resource when you’re done so the NAT Gateway stops billing you.

* Delete the demo resources so no workloads are left running:

```bash
kubectl delete -f manifests/demo.yaml
```

* Destroy the stack:

```bash
terraform destroy
```

## Cost and Security Notes

- Cost: The NAT Gateway is the most expensive component (~$0.045/hr). Run the demo, capture outputs for future labs, then destroy.
- Security: Use least privilege IAM. Rotate or delete the Terraform role once you finish. Secrets belong in AWS Secrets Manager or Parameter Store, not in Terraform variables.
- Networking: Public API access is enabled for speed. In production, restrict `cluster_endpoint_public_access` or add source CIDRs.
- CI access: When you automate this later, pair Terraform Cloud or GitHub Actions with OIDC as outlined in [Use GitHub Actions OIDC for short-lived AWS creds](./posts/devops/stop-using-access-keys-github-actions-aws.md).

## Validation Checklist

- `terraform apply` completed without errors and outputs rendered.
- `kubectl get nodes` shows at least one Auto Mode managed node.
- `kubectl rollout status deployment/hello-auto-mode` reports `successfully rolled out`.
- Port forward returns the default Nginx welcome page.

## Next Steps

- Swap the demo Deployment with your own microservice and test Auto Mode scaling.
- Add Terraform workspaces or Terragrunt to promote the cluster into shared test accounts.

## References

- <a href="https://docs.aws.amazon.com/eks/latest/userguide/automode.html" target="_blank" rel="noopener">AWS EKS Auto Mode documentation</a>
- <a href="https://github.com/terraform-aws-modules/terraform-aws-eks" target="_blank" rel="noopener">terraform-aws-eks module on GitHub</a>
- <a href="https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/latest" target="_blank" rel="noopener">Amazon VPC module docs</a>


## Key Takeaways

1. Auto Mode removes node group plumbing, but Terraform still needs explicit `cluster_compute_config` settings.
2. Keep IAM permissive only in sandboxes; harden before production.
3. Destroy the stack right after validation to keep the lab under $5.

---
