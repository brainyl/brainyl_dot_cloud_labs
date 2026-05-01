# ECS Full Demo - Infrastructure

Terraform infrastructure for deploying a full-stack application (Vue.js, FastAPI, MySQL) to AWS ECS Fargate.

## Quick Start

```bash
# 1. Bootstrap (creates ECR, Secrets, AppConfig)
cd bootstrap
terraform init && terraform apply

# 2. Main Infrastructure (creates VPC, ECS, ALB, etc.)
cd ..
terraform init && terraform apply

# 3. Access your application
terraform output alb_dns_name
```

---

## Architecture

```
Internet → ALB → Frontend → Backend → MySQL
                                       ↓
                                      EFS
```

**Key Features:**
- ✅ **ECS Service Connect** - Simple service discovery (`mysql` not `mysql.namespace.local`)
- ✅ **EFS for MySQL** - Persistent data storage across container restarts
- ✅ **Secrets Manager** - Random passwords, manual rotation
- ✅ **Multi-AZ** - High availability across 2 availability zones
- ✅ **ECS Exec** - Debug containers with `aws ecs execute-command`
- ✅ **CloudWatch Logs** - All services log to stdout/stderr

---

## Two-Layer Deployment

### Layer 1: Bootstrap (Deploy First)

**What:** ECR repos, Secrets, AppConfig  
**Why:** Must exist before CI/CD can push images  
**When:** Once per environment

```bash
cd bootstrap
terraform init
terraform apply
```

**Creates:**
- ECR repositories: `simple-app-dev-{mysql,backend,frontend}`
- Secrets: Random MySQL passwords (32 chars)
- AppConfig: For storing deployment manifests

### Layer 2: Main Infrastructure (Deploy Second)

**What:** VPC, ECS cluster, services, ALB, EFS  
**Why:** Runtime environment for your application  
**When:** After bootstrap, updates as needed

```bash
cd infrastructure
terraform init
terraform apply
```

**Creates:**
- VPC with public/private subnets
- ECS cluster with Service Connect
- 3 ECS services (MySQL, Backend, Frontend)
- Application Load Balancer
- EFS for MySQL data
- IAM roles, Security groups

**Why separate?** Bootstrap resources rarely change. Main infrastructure changes frequently. This prevents circular dependencies and enables CI/CD.

---

## Configuration

### Bootstrap Variables

```hcl
# bootstrap/terraform.tfvars
project_name = "simple-app"
environment  = "dev"
aws_region   = "us-east-1"
```

### Main Infrastructure Variables

```hcl
# infrastructure/terraform.tfvars
project_name = "simple-app"
environment  = "dev"
aws_region   = "us-east-1"

# Optional
enable_nat_gateway = true   # false for dev to save $32/month
mysql_cpu         = 512     # 256 for dev
mysql_memory      = 1024    # 512 for dev
```

---

## Service Connect (Not Cloud Map)

This infrastructure uses **ECS Service Connect** for service discovery:

**Backend connects to MySQL:**
```python
DB_HOST = "mysql"  # Simple name, not FQDN!
```

**Benefits:**
- ✅ No separate Cloud Map namespace
- ✅ Instant updates (no DNS propagation)
- ✅ Built-in load balancing
- ✅ Automatic health checks
- ✅ CloudWatch metrics included
- ✅ No extra cost

**How it works:**
1. Cluster configured with namespace: `simple-app-dev.local`
2. Services expose named ports: `portName: "mysql"`
3. Service Connect resolves `mysql` → healthy tasks
4. Automatic failover and load balancing

---

## Deployment Steps

### 1. Deploy Bootstrap

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars
terraform init
terraform apply
```

**Save outputs:**
```bash
terraform output summary
```

### 2. Configure GitHub (Optional)

Add AppConfig IDs to GitHub secrets for CI/CD:
- `APPCONFIG_APPLICATION_ID`
- `APPCONFIG_ENVIRONMENT_ID`
- `APPCONFIG_PROFILE_ID`
- `AWS_ROLE_ARN` (for OIDC)

### 3. Deploy Main Infrastructure

```bash
cd ../infrastructure
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars
terraform init
terraform apply
```

### 4. Push Images (Optional)

Let CI/CD do this, or push manually:

```bash
# ECR login
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin <account-id>.dkr.ecr.us-east-1.amazonaws.com

# Build and push
docker build -t <ecr-url>/simple-app-dev-mysql:latest ./mysql
docker push <ecr-url>/simple-app-dev-mysql:latest
```

### 5. Verify

```bash
# Check services
aws ecs list-services --cluster simple-app-dev-cluster

# View logs
aws logs tail /ecs/simple-app-dev/backend --follow

# Access application
curl http://$(terraform output -raw alb_dns_name)
```

---

## Module Structure

```
infrastructure/
├── bootstrap/              # ECR, Secrets, AppConfig
├── modules/
│   ├── networking/         # VPC, subnets, security groups
│   ├── ecs-cluster/        # ECS cluster with Service Connect
│   ├── iam/                # Task execution + task roles
│   ├── alb/                # Application Load Balancer
│   └── ecs-service/        # Reusable service module
└── main.tf                 # Orchestrates everything
```

---

## Secrets Management

### Architecture: Separation of Concerns

**Terraform manages:**
- Secrets (AWS Secrets Manager ARNs)
- Infrastructure configuration (volumes, IAM, networking)

**AppConfig manages:**
- Environment variables (non-sensitive application config)
- Container image tags
- Resource sizing

This separation allows:
- ✅ Application teams to update env vars without Terraform
- ✅ Infrastructure teams to rotate secrets independently
- ✅ Clean separation between infrastructure and application config

### Configuration Flow

```
┌─────────────────────────────────────────────────────────────┐
│                    Configuration Sources                     │
├──────────────────────────────┬──────────────────────────────┤
│         Terraform            │         AppConfig            │
│    (Infrastructure)          │      (Application)           │
├──────────────────────────────┼──────────────────────────────┤
│ • Secrets (ARNs)             │ • Environment Variables      │
│ • Volumes                    │ • Image Tags                 │
│ • IAM Roles                  │ • Feature Flags              │
│ • Networking                 │ • Application Config         │
└──────────────────────────────┴──────────────────────────────┘
                               │
                               ▼
                    ┌──────────────────────┐
                    │   ECS Task Definition │
                    │   (Merged at Deploy)  │
                    └──────────────────────┘
```

### Initial Setup (Bootstrap)

Bootstrap creates **version 0** of the AppConfig manifest with baseline configuration:

```json
{
  "version": "1.0",
  "services": {
    "backend": {
      "image": "123.dkr.ecr.us-west-2.amazonaws.com/backend:latest",
      "environment": {
        "DB_HOST": "mysql",
        "DB_PORT": "3306",
        "DB_NAME": "simpledb"
      }
    }
  }
}
```

This ensures deployment workflows have valid configuration from the start. CI/CD updates this with actual image tags on first build.

### Secret Creation (Bootstrap)

Secrets are created in bootstrap with random passwords:

```hcl
resource "random_password" "mysql_root" {
  length  = 32
  special = true
}

resource "aws_secretsmanager_secret_version" "mysql_root_password" {
  secret_id     = aws_secretsmanager_secret.mysql_root_password.id
  secret_string = random_password.mysql_root.result
  
  lifecycle {
    ignore_changes = [secret_string]  # Allow manual rotation
  }
}
```

### Secret Injection (Runtime)

**ECS injects secrets at runtime:**
```json
{
  "secrets": [
    {
      "name": "DB_PASSWORD",
      "valueFrom": "arn:aws:secretsmanager:us-east-1:123456789012:secret:mysql/simple-app/app-password-AbCdEf"
    }
  ]
}
```

Application reads as environment variable:
```python
DB_PASSWORD = os.getenv("DB_PASSWORD")  # ECS injects this
```

### Updating Secrets (Rare)

When you need to rotate secrets or add new ones:

```bash
# 1. Update bootstrap (if creating new secrets)
cd bootstrap
terraform apply

# 2. Update main infrastructure (reference new secret ARNs)
cd ../infrastructure
# Edit main.tf to add/update secret references

# 3. Apply changes and redeploy services
../scripts/apply-secret-changes.sh
```

The helper script:
1. Applies Terraform changes (updates task definitions with new secret ARNs)
2. Forces ECS to redeploy all services (picks up new secrets)

**Why the helper script?**
- Terraform uses `ignore_changes = [container_definitions]` to avoid conflicts with CI/CD
- This means secret changes in Terraform won't automatically trigger redeployment
- The script forces ECS to use the updated task definition

### Updating Environment Variables (Frequent)

Application teams can update env vars without Terraform:

**Via CI/CD (Recommended):**
1. Update environment variables in build workflow
2. Push to GitHub
3. CI/CD builds and publishes new manifest to AppConfig
4. Deploy workflow applies changes

**Important:** The build workflow **merges** environment variables, it doesn't replace them:
- Env vars defined in the workflow are always included
- Manually added env vars in AppConfig are preserved
- To remove an env var, you must manually edit AppConfig

**Via Manual AppConfig Update:**
```bash
# Download current manifest
aws appconfig get-hosted-configuration-version \
  --application-id $APP_ID \
  --configuration-profile-id $PROFILE_ID \
  --version-number $VERSION \
  current-manifest.json

# Edit the manifest (add/remove env vars)
# Then upload new version
aws appconfig create-hosted-configuration-version \
  --application-id $APP_ID \
  --configuration-profile-id $PROFILE_ID \
  --content file://updated-manifest.json
```

**Example workflow:**
```bash
# 1. Manually add LOG_LEVEL to AppConfig
# AppConfig now has: DB_HOST, DB_PORT, LOG_LEVEL

# 2. Push code change (triggers build)
# Build workflow defines: DB_HOST, DB_PORT, DB_NAME

# 3. Result after merge:
# AppConfig has: DB_HOST, DB_PORT, DB_NAME, LOG_LEVEL
# ✅ LOG_LEVEL is preserved!
```

**Example AppConfig manifest:**
```json
{
  "services": {
    "backend": {
      "image": "...",
      "environment": {
        "DB_HOST": "mysql",
        "DB_PORT": "3306",
        "LOG_LEVEL": "debug",
        "FEATURE_FLAG_X": "true",
        "API_TIMEOUT": "30"
      }
    }
  }
}
```

### Common Scenarios

**Scenario 1: Add Feature Flag**
```bash
# Update build workflow to include new env var
# Push to GitHub → CI/CD handles the rest
# No Terraform changes needed!
```

**Scenario 2: Rotate Database Password**
```bash
# Update secret value in AWS Console
aws secretsmanager update-secret \
  --secret-id mysql/simple-app/app-password-xyz \
  --secret-string "new-password"

# Force ECS redeployment
aws ecs update-service \
  --cluster simple-app-dev-cluster \
  --service simple-app-dev-backend \
  --force-new-deployment
```

**Scenario 3: Add New Secret**
```bash
# 1. Create secret in bootstrap
cd bootstrap
# Add new secret resource to main.tf
terraform apply

# 2. Reference secret in main infrastructure
cd ../infrastructure
# Add secret to service in main.tf

# 3. Apply and redeploy
../scripts/apply-secret-changes.sh
```

### Best Practices

**Do's ✅**
- Use AppConfig for application config (fast iteration)
- Use Terraform for secrets (audit trail, control)
- Use helper script for secret changes
- Version your manifests in AppConfig
- Test in dev first

**Don'ts ❌**
- Don't put secrets in AppConfig
- Don't manually edit task definitions
- Don't skip the helper script for secret changes
- Don't remove `ignore_changes` from task definitions
- Don't hardcode values

---

## Monitoring

```bash
# View logs
aws logs tail /ecs/simple-app-dev/mysql --follow
aws logs tail /ecs/simple-app-dev/backend --follow
aws logs tail /ecs/simple-app-dev/frontend --follow

# ECS Exec into container
aws ecs execute-command \
  --cluster simple-app-dev-cluster \
  --task <task-id> \
  --container backend \
  --interactive \
  --command "/bin/bash"

# Check service health
aws ecs describe-services \
  --cluster simple-app-dev-cluster \
  --services mysql backend frontend
```

---

## Cost Optimization

### Development
```hcl
enable_nat_gateway = false  # Save ~$32/month
mysql_cpu         = 256
mysql_memory      = 512
```
**Estimated:** ~$50-70/month

### Production
```hcl
enable_nat_gateway = true
mysql_cpu         = 512
mysql_memory      = 1024
```
**Estimated:** ~$150-200/month

---

## Troubleshooting

### Services not starting
```bash
# Check task status
aws ecs describe-tasks --cluster simple-app-dev-cluster --tasks <task-id>

# View logs
aws logs tail /ecs/simple-app-dev/backend --follow
```

### Health checks failing
```bash
# Check target health
aws elbv2 describe-target-health --target-group-arn <arn>
```

### Can't connect to MySQL
```bash
# Verify Service Connect
aws ecs describe-services \
  --cluster simple-app-dev-cluster \
  --services mysql backend \
  --query 'services[*].serviceConnectConfiguration'
```

**Common issue:** Using FQDN instead of short name
- ✅ Correct: `DB_HOST=mysql`
- ❌ Wrong: `DB_HOST=mysql.simple-app-dev.local`

---

## Cleanup

```bash
# Destroy main infrastructure
cd infrastructure
terraform destroy

# Destroy bootstrap
cd bootstrap
terraform destroy
```

**Warning:** This deletes:
- All ECS services and tasks
- EFS file system (MySQL data lost!)
- ECR repositories and images
- All networking resources

---

## Next Steps

1. ✅ Configure custom domain with Route53
2. ✅ Add ACM certificate for HTTPS
3. ✅ Set up CloudWatch alarms
4. ✅ Configure auto-scaling policies
5. ✅ Enable AWS Backup for EFS
6. ✅ Add WAF for ALB (production)

---

## Key Differences from Traditional Setup

| Feature | This Setup | Traditional |
|---------|-----------|-------------|
| **Service Discovery** | ECS Service Connect | AWS Cloud Map |
| **DNS Names** | `mysql` | `mysql.namespace.local` |
| **Secrets** | ECS native injection | Application pulls from SDK |
| **Bootstrap** | Separate layer | Monolithic |
| **CI/CD** | OIDC (keyless) | Long-lived credentials |
| **Deployment** | AppConfig manifests | Direct ECS updates |

---

## Support

**Documentation:**
- `bootstrap/README.md` - Bootstrap layer details
- Application: `../fullstack-app/README.md`
- CI/CD: `../.github/workflows/ecs-full-demo/README.md`

**Common Issues:**
1. Check CloudWatch logs first
2. Verify security group rules
3. Confirm Service Connect configuration
4. Check IAM role permissions
