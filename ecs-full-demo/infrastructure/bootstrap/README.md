# Bootstrap Infrastructure

This directory contains the **bootstrap layer** of the infrastructure - foundational resources that must exist before the main infrastructure and CI/CD pipelines can run.

## What's in Bootstrap?

### 1. ECR Repositories
Container registries for all services:
- `simple-app-dev-mysql`
- `simple-app-dev-backend`
- `simple-app-dev-frontend`

These must exist before GitHub Actions can push Docker images.

### 2. Secrets Manager
Randomized passwords for MySQL:
- **Root Password**: `mysql/simple-app/root-password-*`
- **App User Password**: `mysql/simple-app/app-password-*`

Passwords are generated with `random_password` and use `ignore_changes` lifecycle, allowing manual rotation in AWS Console without Terraform overwriting them.

### 3. AppConfig
Application configuration for deployment manifests:
- **Application**: Deployment manifests container
- **Environment**: Matches your environment (dev/staging/production)
- **Configuration Profile**: Hosted configuration for deployment data
- **Deployment Strategy**: Immediate deployment (0 minutes)
- **Initial Configuration (Version 0)**: Baseline manifest with placeholder images

GitHub Actions publishes deployment manifests here, which deployment scripts retrieve to update ECS services.

**Initial Configuration:**
Bootstrap creates version 0 of the AppConfig manifest with:
- Placeholder image tags (`:latest`)
- Default environment variables
- Resource allocations (CPU/memory)

This ensures the deployment workflow has a valid manifest to work with from the start. CI/CD will update this with actual image tags on the first build.

## Why Separate Bootstrap?

Bootstrap resources have different lifecycle requirements:

1. **ECR repos must exist before CI/CD runs** - GitHub Actions needs somewhere to push images
2. **Secrets should be created once** - Passwords shouldn't change on every `terraform apply`
3. **AppConfig is shared infrastructure** - Used by both CI/CD and deployment processes
4. **Prevents circular dependencies** - Main infrastructure references ECR URLs, but ECR needs to exist first

See `../DEPENDENCIES.md` for detailed explanation.

## Deployment

### Step 1: Configure Variables

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:
```hcl
project_name     = "simple-app"
environment      = "dev"
aws_region       = "us-west-2"
ecr_repositories = ["mysql", "backend", "frontend"]
```

### Step 2: Initialize and Apply

```bash
terraform init
terraform apply
```

### Step 3: Save Outputs

```bash
terraform output summary
```

This will show:
- ECR repository URLs (for pushing images)
- Secrets Manager ARNs (for main infrastructure)
- AppConfig IDs (for GitHub Actions)

### Step 4: Configure GitHub Secrets

Add these secrets to your GitHub repository:

```bash
# Get the values
terraform output appconfig_application_id
terraform output appconfig_environment_id
terraform output appconfig_profile_id
terraform output appconfig_deployment_strategy_id
```

Add to GitHub repository secrets:
- `APPCONFIG_APPLICATION_ID`
- `APPCONFIG_ENVIRONMENT_ID`
- `APPCONFIG_PROFILE_ID`
- `APPCONFIG_DEPLOYMENT_STRATEGY_ID`
- `AWS_REGION`
- `AWS_ACCOUNT_ID`

## Resources Created

### ECR Repositories
- **Lifecycle Policy**: Keep last 10 tagged images, remove untagged after 7 days
- **Image Scanning**: Enabled on push
- **Encryption**: AES256

### Secrets Manager
- **Recovery Window**: 7 days
- **Password Length**: 32 characters
- **Special Characters**: Enabled
- **Lifecycle**: `ignore_changes` on secret value (allows manual rotation)

### AppConfig
- **Application**: Container for all deployment configurations
- **Environment**: Matches your Terraform environment variable
- **Profile**: Hosted configuration (stored in AppConfig, not S3)
- **Strategy**: Immediate deployment (no gradual rollout)
- **Initial Version**: Version 0 created with baseline configuration
  - Uses `:latest` image tags as placeholders
  - Includes default environment variables
  - CI/CD will update with actual image tags on first build

## Outputs

```hcl
mysql_root_password_secret_arn    # ARN for root password secret
mysql_app_password_secret_arn     # ARN for app user password secret
ecr_repository_urls               # Map of service name to ECR URL
ecr_repository_arns               # Map of service name to ECR ARN
appconfig_application_id          # AppConfig application ID
appconfig_environment_id          # AppConfig environment ID
appconfig_profile_id              # AppConfig profile ID
appconfig_deployment_strategy_id  # AppConfig strategy ID
initial_config_version            # Initial AppConfig version number (usually 1)
summary                           # Human-readable summary of all resources
```

## Next Steps

After bootstrap is deployed:

1. **Push Initial Images** (optional, but recommended):
   ```bash
   # Get ECR login
   aws ecr get-login-password --region us-west-2 | \
     docker login --username AWS --password-stdin <account-id>.dkr.ecr.us-west-2.amazonaws.com
   
   # Build and push (from fullstack-app directory)
   docker build -t simple-app-dev-mysql:latest ./mysql
   docker tag simple-app-dev-mysql:latest <ecr-url>/simple-app-dev-mysql:latest
   docker push <ecr-url>/simple-app-dev-mysql:latest
   ```

2. **Deploy Main Infrastructure**:
   ```bash
   cd ../
   terraform init
   terraform apply
   ```

3. **Configure GitHub Actions**:
   - Add AppConfig IDs as repository secrets
   - Push code to trigger CI/CD pipeline

## Updating Bootstrap

Bootstrap resources are designed to be stable. However, if you need to update:

```bash
# Plan changes
terraform plan

# Apply changes
terraform apply
```

**Note**: Changing `project_name` or `environment` will create new resources with different names.

## Cleanup

To destroy bootstrap resources:

```bash
terraform destroy
```

**Warning**: This will:
- Delete all ECR repositories and their images
- Delete Secrets Manager secrets (after 7-day recovery window)
- Delete AppConfig configuration

Make sure to destroy the main infrastructure first, as it depends on these resources.

## Troubleshooting

### ECR Repository Already Exists

If you get an error that a repository already exists:
```bash
# Check existing repositories
aws ecr describe-repositories --region us-west-2

# Import existing repository
terraform import 'module.ecr["mysql"].aws_ecr_repository.this[0]' simple-app-dev-mysql
```

### Secrets Already Exist

Secrets use `name_prefix` with random suffix, so conflicts are rare. If needed:
```bash
# List existing secrets
aws secretsmanager list-secrets --region us-west-2

# Import existing secret
terraform import aws_secretsmanager_secret.mysql_root_password <secret-arn>
```

### AppConfig Already Exists

AppConfig resources use deterministic names. If they exist:
```bash
# Import existing application
terraform import aws_appconfig_application.main <application-id>
```

## Cost

Bootstrap resources have minimal cost:
- **ECR**: $0.10/GB/month for storage (only for stored images)
- **Secrets Manager**: $0.40/secret/month + $0.05 per 10,000 API calls
- **AppConfig**: Free tier covers most usage

Estimated monthly cost: **~$1-2** for dev environment with minimal images.

## Security

### ECR
- Private repositories (not publicly accessible)
- Image scanning enabled
- Encryption at rest (AES256)

### Secrets Manager
- Encrypted at rest (AWS managed key)
- Encrypted in transit (TLS)
- Access controlled via IAM
- Automatic rotation supported (manual setup required)

### AppConfig
- Configuration data is not encrypted by default
- Access controlled via IAM
- Does not store sensitive data (only deployment metadata)

## Variables Reference

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `project_name` | string | `"simple-app"` | Project identifier |
| `environment` | string | `"dev"` | Environment name |
| `aws_region` | string | `"us-west-2"` | AWS region |
| `ecr_repositories` | list(string) | `["mysql", "backend", "frontend"]` | ECR repos to create |

## Module Dependencies

This bootstrap layer uses:
- [terraform-aws-modules/ecr/aws](https://registry.terraform.io/modules/terraform-aws-modules/ecr/aws) (~> 2.0)
- [hashicorp/random](https://registry.terraform.io/providers/hashicorp/random) (~> 3.0)
