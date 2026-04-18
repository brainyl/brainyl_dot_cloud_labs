IRSA solved a real problem when it arrived, but anyone who has wrestled with IAM trust policies and opaque webhooks knows it is too easy to misconfigure. **EKS Pod Identity** finally delivers a managed way to connect Kubernetes service accounts to IAM roles without the YAML gymnastics.

For teams running Kubernetes on AWS, this is the cleanest path yet to keep secure EKS workloads aligned with least privilege. Instead of juggling federated trust documents, you focus on Terraform, apply, and move on.

In this playbook you will stand up Terraform resources that register a pod identity association, bind it to a namespace, and deploy a sample workload that can call AWS APIs securely.

If you still need an example cluster, jump to the EKS Auto Mode bootstrap guide in the [Build EKS Auto Mode with Terraform](/eks-auto-mode-quick-bootstrap-terraform) post and come back once it is running. By default, the EKS Pod Identity Agent is pre-installed on EKS Auto Mode clusters, so the association will work as soon as Terraform applies.

By the end, you will understand why Pod Identity is becoming the new default over IRSA, how to configure it in Terraform, and how to verify that your pods only perform the AWS actions you approve.

### What You’ll Build

You will use Terraform to provision an IAM role with a least-privilege policy, register an EKS pod identity association for a specific service account, and roll out a sample deployment that inherits those AWS permissions. Verification is as simple as running an exec command and observing that the pod can perform its authorized AWS action—nothing more.

```
Client shell → Terraform → AWS IAM + EKS Pod Identity → Kubernetes Service Account → Sample pod with scoped AWS access
```

| Component | Purpose |
|-----------|---------|
| Terraform | Define IAM roles, policies, and the pod identity association |
| AWS IAM   | Grants least-privilege permissions for the target workload |
| EKS Pod Identity | Bridges IAM roles to Kubernetes service accounts |
| Sample Deployment | Demonstrates pods inheriting the scoped AWS permissions |

### Prerequisites

- AWS account in **us-west-2** with permissions to manage IAM, EKS, and CloudWatch Logs.
- Tools: Terraform v1.13.4+, AWS CLI v2, kubectl v1.34+, and Docker if you build custom images.
- An existing EKS cluster running Kubernetes 1.34+ (use the auto mode setup linked above if you need a starting point).
- Local kubeconfig pointing at the target cluster and authenticated with cluster admin privileges.
- Estimated cost: Expect to pay for the EKS control plane and any worker nodes while the cluster is running. Destroy resources when finished to avoid ongoing charges.

### Step-by-Step Playbook

This eks terraform workflow keeps everything in source control so you can review changes before touching the cluster.

#### 1. Clone the Terraform baseline

Create a fresh working directory and initialize the Terraform files:

```bash
mkdir eks-pod-identity && cd eks-pod-identity
```

Create `versions.tf`:

```terraform
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
  }
}

provider "aws" {
  region = var.region
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}
```

Add supporting variables and data sources. Create `variables.tf`:

```terraform
variable "cluster_name" {
  type        = string
  description = "Name of the EKS cluster to bind the pod identity association to."
}

variable "region" {
  type        = string
  default     = "us-west-2"
  description = "AWS region where the cluster runs."
}

variable "namespace" {
  type        = string
  default     = "pod-identity-demo"
  description = "Namespace that will host the service account and workloads."
}
```

Create `data.tf`:

```terraform
data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

data "aws_eks_cluster_auth" "this" {
  name = var.cluster_name
}

data "aws_caller_identity" "current" {}
```

Surface the namespace at apply time so you can reuse it in later commands. Create `outputs.tf`:

```terraform
output "namespace" {
  description = "Namespace that hosts the pod identity demo workload."
  value       = var.namespace
}

output "role_arn" {
  description = "IAM role assumed by pods via EKS Pod Identity."
  value       = aws_iam_role.pod_identity.arn
}
```

#### 2. Create the IAM role and policy

EKS Pod Identity removes the need for the OIDC provider configuration that IRSA requires. You still need an IAM role with a trust policy that allows the Pod Identity agent to assume it on behalf of your pods. Create `iam.tf`:

```terraform
locals {
  account_id = data.aws_caller_identity.current.account_id
  policy_name = "pod-identity-demo-cloudwatch"
}

resource "aws_iam_role" "pod_identity" {
  name = "${var.cluster_name}-pod-identity"

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

resource "aws_iam_policy" "pod_identity" {
  name        = local.policy_name
  description = "Allow writing logs to CloudWatch for demo purposes."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.region}:${local.account_id}:*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "pod_identity" {
  role       = aws_iam_role.pod_identity.name
  policy_arn = aws_iam_policy.pod_identity.arn
}
```

This role is far simpler than the IRSA equivalent because AWS operates the identity agent and no longer requires you to manage a thumbprint or IAM OIDC provider.

#### 3. Associate the role with a Kubernetes service account

Now connect the IAM role to a namespace and service account using the `aws_eks_pod_identity_association` resource. Create `pod_identity.tf`:

```terraform
resource "aws_eks_pod_identity_association" "demo" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = "cw-writer"
  role_arn        = aws_iam_role.pod_identity.arn
}

resource "kubernetes_namespace" "demo" {
  metadata {
    name = var.namespace
  }
}

resource "kubernetes_service_account" "demo" {
  metadata {
    name      = aws_eks_pod_identity_association.demo.service_account
    namespace = var.namespace
    labels = {
      "app" = "cw-writer"
    }
  }
}
```

With IRSA you would annotate the service account with the IAM role ARN; Pod Identity removes that requirement. The association handles all of the mapping.

#### 4. Deploy a workload that uses the identity

Create a simple deployment that uses the service account. The pod uses the `amazon/aws-cli` image to emit a test log entry so you can confirm permissions without building a custom container. Create `workload.tf`:

```terraform
resource "kubernetes_deployment" "demo" {
  metadata {
    name      = "cw-writer"
    namespace = var.namespace
    labels = {
      app = "cw-writer"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "cw-writer"
      }
    }

    template {
      metadata {
        labels = {
          app = "cw-writer"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.demo.metadata[0].name

        container {
          name  = "aws-cli"
          image = "amazon/aws-cli:2.17.50"
          command = ["/bin/sh", "-c"]
          args = [
            <<-EOT
            aws logs create-log-group --log-group-name /demo/pod-identity --region ${var.region} || true && \
            aws logs create-log-stream --log-group-name /demo/pod-identity --log-stream-name $HOSTNAME --region ${var.region} || true && \
            aws logs put-log-events --log-group-name /demo/pod-identity --log-stream-name $HOSTNAME --log-events '[{"timestamp":'$(($(date +%s%3N)))',"message":"hello from pod identity"}]' --region ${var.region} && \
            sleep 3600
            EOT
          ]
        }
      }
    }
  }
}
```

Apply the configuration:

```bash
terraform init
terraform apply -auto-approve \
  -var "cluster_name=YOUR_CLUSTER_NAME" \
  -var "region=us-west-2"
```

Within a minute the deployment starts and the pod identity agent injects temporary credentials tied to the IAM role you created.

#### 5. Validate from the cluster

Confirm the pod is running and can call AWS APIs using the scoped role:

```bash
kubectl get pods -n pod-identity-demo

POD_NAME=$(kubectl get pods -n pod-identity-demo -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n pod-identity-demo "$POD_NAME" -- aws sts get-caller-identity --region us-west-2
terraform output -raw role_arn
```

You should see the IAM role ARN in the output. Compare it with `terraform output -raw role_arn` to confirm that the pod is assuming the intended identity without any IRSA annotations.

#### 6. Compare with IRSA

Key differences to call out for teams migrating from IRSA:

- **No manual OIDC provider** - Pod Identity ships with a managed agent, eliminating the shared responsibility of rotating thumbprints.
- **Simpler Terraform** - The `aws_eks_pod_identity_association` resource replaces the mix of IAM roles, IAM OpenID providers, and service account annotations.
- **Granular adoption** - You can migrate namespace by namespace while IRSA workloads continue running until you switch them.
- **Operational visibility** - CloudWatch and `kubectl describe` show the association status, making drift detection easier than chasing webhook logs.

When you need to rotate permissions, update the IAM policy and re-apply. No redeploy of the pod is required because the agent delivers temporary credentials automatically.

### Observability and Logging

Check `/demo/pod-identity` in CloudWatch Logs to confirm the sample deployment created a log stream. You can also enable `aws eks list-pod-identity-associations` to review associations programmatically and feed that into your compliance pipelines.

### Cleanup

Destroy resources once you finish testing:

```bash
terraform destroy -auto-approve \
  -var "cluster_name=YOUR_CLUSTER_NAME" \
  -var "region=us-west-2"
```

Delete the CloudWatch log group if you do not need the test data:

```bash
aws logs delete-log-group --log-group-name /demo/pod-identity --region us-west-2
```

Finally, remove the working directory and, if the cluster is no longer needed, follow the teardown steps in the auto mode guide.

### Related Reading

- Bootstrap an EKS Auto Mode cluster quickly with [EKS Auto Mode Quick Bootstrap with Terraform](/eks-auto-mode-quick-bootstrap-terraform).
- Secure GitHub Actions runners without keys using [Stop Managing GitHub Actions Access Keys for AWS](./stop-using-access-keys-github-actions-aws.md).
- Keep private connectivity solid with [Expose Services Safely with AWS PrivateLink](./vpc-endpoint-service-private-connectivity.md).

External references:

- <a href="https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html" target="_blank" rel="noreferrer">AWS EKS Pod Identity documentation</a>
- <a href="https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association" target="_blank" rel="noreferrer">Terraform aws_eks_pod_identity_association resource</a>
- <a href="https://aws.amazon.com/about-aws/whats-new/2023/11/amazon-eks-pod-identity/" target="_blank" rel="noreferrer">AWS announcement for EKS Pod Identity</a>

### Takeaways

1. EKS Pod Identity eliminates the brittle parts of IRSA by letting AWS run the identity agent for you.
2. Terraform can model the entire workflow—IAM role, permissions, association, and workload—in under 200 lines.
3. Workloads inherit just the IAM actions you allow, and verification is as easy as running a single kubectl command.

Destroy the demo when you are done so your AWS bill and IAM surface area stay tidy.
