
Shipping infrastructure from GitHub Actions with long-lived AWS access keys is a risky pattern.
Keys leak through CI logs, forked repositories, or compromised runners, and rotating them across dozens of workflows is painful.

AWS and GitHub solved this class of problems with OpenID Connect (OIDC) federation: GitHub issues a short-lived identity token that AWS trusts, and your workflow exchanges it for a role session that can run the AWS CLI without ever handling secrets.

This guide shows how to stand up the trust relationship in Terraform, attach the precise permissions you need (an SNS topic in this example), and call the role from a GitHub workflow using `sts:AssumeRoleWithWebIdentity`.

## 1. Terraform: Trust GitHub's OIDC Provider

First, tell AWS to trust the GitHub Actions OIDC issuer. The TLS thumbprint validates the certificate chain used by `https://token.actions.githubusercontent.com`.

Create `oidc.tf`:

```terraform
data "tls_certificate" "oidc_thumbprint" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [for cert in data.tls_certificate.oidc_thumbprint.certificates : lookup(cert, "sha1_fingerprint", "")]
}
```

Create `variables.tf`:

```terraform
variable "org" {
  type        = string
  description = "GitHub organization name (e.g., 'myorg' for github.com/myorg)"
}
```

## 2. Terraform: Create a Scoped IAM Role

Next, create an IAM role that GitHub can assume. Scope the `sub` condition to the repositories (or environments) you trust. This example matches any repository under your organization, but you can pin it to specific repos or environments by setting the subject to `repo:ORG/REPO:environment:prod`.

Create `iam.tf`:

```terraform
resource "aws_iam_role" "github_ci" {
  name                 = "github-oidc-sns"
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Principal" : {
          "Federated" : aws_iam_openid_connect_provider.github.arn
        },
        "Action" : "sts:AssumeRoleWithWebIdentity",
        "Condition" : {
          "ForAnyValue:StringLike" : {
            "token.actions.githubusercontent.com:sub" : [
              "repo:${var.org}/*"
            ]
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "github_ci_sns" {
  name = "github-ci-create-sns"
  role = aws_iam_role.github_ci.id

  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Sid" : "CreateSnsTopic",
        "Effect" : "Allow",
        "Action" : [
          "sns:CreateTopic",
          "sns:TagResource"
        ],
        "Resource" : "*"
      }
    ]
  })
}
```

💡 Tip: Keep the policy tight. If the workflow also needs to publish messages, add `sns:Publish` but still scope resources wherever possible.

Create `outputs.tf`:

```terraform
output "role_arn" {
  description = "IAM role ARN for GitHub Actions OIDC"
  value       = aws_iam_role.github_ci.arn
}
```

Apply the Terraform configuration with your GitHub organization name:

```bash
terraform init
terraform apply -var="org=your-github-org"
```

## 3. Store the Role ARN as a Repository Secret

After applying Terraform, capture the role ARN from the output:

```bash
terraform output -raw role_arn
```

In GitHub, navigate to your repository and add the role ARN as an Actions secret:

1. Go to **Settings** → **Secrets and variables** → **Actions**
2. Click **New repository secret**
3. Name: `AWS_ROLE_TO_ASSUME`
4. Value: Paste the role ARN (e.g., `arn:aws:iam::123456789012:role/github-oidc-sns`)
5. Click **Add secret**

You do **not** need to store access keys—only the role ARN.

## 4. GitHub Workflow: Assume the Role and Create an SNS Topic

The workflow below runs on `workflow_dispatch`, requests an OIDC token automatically (by setting `permissions: id-token: write`), and feeds it to the AWS CLI via the official credential-action. After the credentials are in place, we call the AWS CLI to create a topic.

Create `.github/workflows/create-sns-topic.yml`:

```yaml
name: create-sns-topic

on:
  workflow_dispatch:
    inputs:
      topic_name:
        description: "SNS topic to create"
        required: true

env:
  AWS_REGION: us-west-2

permissions:
  id-token: write
  contents: read

jobs:
  create-topic:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Configure AWS credentials from OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_TO_ASSUME }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Create SNS topic
        run: |
          aws sns create-topic \
            --name "${{ github.event.inputs.topic_name }}" \
            --tags Key=CreatedBy,Value=GitHubOIDC
```

### Run the Workflow

Since this workflow uses `workflow_dispatch`, you must trigger it manually:

1. Go to your repository on GitHub
2. Click the **Actions** tab
3. Select **create-sns-topic** from the workflow list on the left
4. Click **Run workflow**
5. Enter a topic name (e.g., `my-test-topic`)
6. Click **Run workflow**

When the job runs, GitHub issues a one-time OIDC token for the workflow run. The AWS credentials action swaps that token for temporary credentials scoped to the IAM role, and the `aws sns create-topic` command succeeds without any static secrets.

## 5. Rotating and Extending

* **Rotation:** There is nothing to rotate. OIDC tokens expire immediately after use, and AWS session credentials expire per the `max_session_duration` you set.
* **Environment scoping:** Use GitHub's environments to require approvals or pin the subject condition (`repo:ORG/REPO:environment:prod`).
* **Least privilege:** Split policies per workflow (e.g., separate roles for SNS, Lambda, or CloudFormation) so a compromised workflow cannot pivot across services.

## 6. Troubleshooting Checklist

1. Ensure the Actions workflow has `permissions: id-token: write`.
2. Confirm the IAM role trust policy's `sub` matches the repository, branch, or environment running the workflow.
3. If you're testing locally with `act`, remember it cannot issue real GitHub OIDC tokens.

With this federation pattern in place, you can delete the old access keys, sleep better, and still let GitHub Actions automate your AWS account securely.
