# Simple Full-Stack Application

A minimal full-stack application with Vue.js frontend, FastAPI backend, and MySQL database, designed for AWS ECS deployment.

## Quick Start (Local Development)

```bash
docker-compose up
```

Access at:
- Frontend: http://localhost
- Backend API: http://localhost:8000
- API Docs: http://localhost:8000/docs

## Project Structure

```
fullstack-app/
├── frontend/              # Vue.js 3 + Vite + Nginx
├── backend/               # FastAPI + SQLAlchemy
├── mysql/                 # Custom MySQL 8.0 image
├── docker-compose.yml     # Local development
└── deployment-examples/   # ECS deployment scripts
```

---

## AWS ECS Deployment Guide

### Architecture

```
Internet → ALB → Frontend (Vue.js) → Backend (FastAPI) → MySQL
                                                           ↓
                                                          EFS
```

### Prerequisites

- AWS Account with ECS access
- Terraform deployed (see `../infrastructure/`)
- ECR repositories created
- VPC with public/private subnets

---

## Secrets Manager Setup

ECS injects secrets at runtime as environment variables. Choose one pattern:

### Pattern 1: Separate Secrets (Recommended - Simpler)

**Create secrets:**
```bash
# Username
aws secretsmanager create-secret \
  --name mysql/simple-app/username \
  --secret-string "appuser"

# Password
aws secretsmanager create-secret \
  --name mysql/simple-app/password \
  --secret-string "YourSecurePassword123!"
```

**Get ARNs (note the auto-generated suffix):**
```bash
aws secretsmanager describe-secret --secret-id mysql/simple-app/username --query 'ARN'
# Output: arn:aws:secretsmanager:us-east-1:123456789012:secret:mysql/simple-app/username-AbCdEf

aws secretsmanager describe-secret --secret-id mysql/simple-app/password --query 'ARN'
# Output: arn:aws:secretsmanager:us-east-1:123456789012:secret:mysql/simple-app/password-XyZ123
```

**Task definition:**
```json
{
  "secrets": [
    {
      "name": "DB_USERNAME",
      "valueFrom": "arn:aws:secretsmanager:us-east-1:123456789012:secret:mysql/simple-app/username-AbCdEf"
    },
    {
      "name": "DB_PASSWORD",
      "valueFrom": "arn:aws:secretsmanager:us-east-1:123456789012:secret:mysql/simple-app/password-XyZ123"
    }
  ]
}
```

### Pattern 2: JSON Secret with Key Extraction (AWS RDS Default)

**Create JSON secret:**
```bash
aws secretsmanager create-secret \
  --name mysql/simple-app/credentials \
  --secret-string '{"username":"appuser","password":"YourSecurePassword123!"}'
```

Or use AWS Console → "Credentials for RDS database"

**Get ARN:**
```bash
aws secretsmanager describe-secret --secret-id mysql/simple-app/credentials --query 'ARN'
# Output: arn:aws:secretsmanager:us-east-1:123456789012:secret:mysql/simple-app/credentials-AbCdEf
```

**Task definition (extract JSON keys):**
```json
{
  "secrets": [
    {
      "name": "DB_USERNAME",
      "valueFrom": "arn:aws:secretsmanager:us-east-1:123456789012:secret:mysql/simple-app/credentials-AbCdEf:username::"
    },
    {
      "name": "DB_PASSWORD",
      "valueFrom": "arn:aws:secretsmanager:us-east-1:123456789012:secret:mysql/simple-app/credentials-AbCdEf:password::"
    }
  ]
}
```

**ARN format explained:**
```
arn:aws:secretsmanager:region:account:secret:name-suffix:json-key:version-stage:version-id
                                                          ^^^^^^^^^ ^^^^^^^^^^^^^ ^^^^^^^^^^
                                                          Extract   AWSCURRENT    Optional
                                                          this key  (default)
```

**Advanced - Use previous version during rotation:**
```json
{
  "name": "DB_USERNAME",
  "valueFrom": "arn:aws:secretsmanager:us-east-1:123456789012:secret:mysql/simple-app/credentials-AbCdEf:username:AWSPREVIOUS:"
}
```

### Pattern Comparison

| Feature | Pattern 1: Separate | Pattern 2: JSON |
|---------|---------------------|-----------------|
| **Simplicity** | ✅ Simpler ARN | ❌ Complex ARN |
| **RDS Integration** | Manual | ✅ Auto-created |
| **Rotation** | Individual | Together |
| **IAM Control** | ✅ Per-credential | Per-secret |
| **Version Control** | Basic | ✅ Advanced |
| **Best For** | New apps | RDS-managed |

**Recommendation:** Use Pattern 1 for new applications, Pattern 2 if using AWS RDS automatic credential management.

### IAM Permissions

Task Execution Role needs:
```json
{
  "Effect": "Allow",
  "Action": ["secretsmanager:GetSecretValue", "kms:Decrypt"],
  "Resource": [
    "arn:aws:secretsmanager:us-east-1:123456789012:secret:mysql/simple-app/*"
  ]
}
```

---

## ECS Task Definitions

### MySQL Service

```json
{
  "family": "simple-app-mysql",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "executionRoleArn": "arn:aws:iam::123456789012:role/ecsTaskExecutionRole",
  "taskRoleArn": "arn:aws:iam::123456789012:role/ecsTaskRole",
  "volumes": [
    {
      "name": "mysql-data",
      "efsVolumeConfiguration": {
        "fileSystemId": "fs-xxxxx",
        "transitEncryption": "ENABLED",
        "authorizationConfig": {"iam": "ENABLED"}
      }
    }
  ],
  "containerDefinitions": [
    {
      "name": "mysql",
      "image": "123456789012.dkr.ecr.us-east-1.amazonaws.com/simple-app-mysql:latest",
      "essential": true,
      "portMappings": [{"containerPort": 3306, "protocol": "tcp"}],
      "secrets": [
        {
          "name": "MYSQL_ROOT_PASSWORD",
          "valueFrom": "arn:aws:secretsmanager:us-east-1:123456789012:secret:mysql/simple-app/root-password-AbCdEf"
        },
        {
          "name": "MYSQL_PASSWORD",
          "valueFrom": "arn:aws:secretsmanager:us-east-1:123456789012:secret:mysql/simple-app/app-password-XyZ123"
        }
      ],
      "environment": [
        {"name": "MYSQL_DATABASE", "value": "simpledb"},
        {"name": "MYSQL_USER", "value": "appuser"}
      ],
      "mountPoints": [
        {
          "sourceVolume": "mysql-data",
          "containerPath": "/var/lib/mysql",
          "readOnly": false
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/simple-app-mysql",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "healthCheck": {
        "command": ["CMD-SHELL", "mysqladmin ping -h localhost -u root -p$MYSQL_ROOT_PASSWORD || exit 1"],
        "interval": 30,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 60
      }
    }
  ]
}
```

### Backend Service

```json
{
  "family": "simple-app-backend",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "arn:aws:iam::123456789012:role/ecsTaskExecutionRole",
  "containerDefinitions": [
    {
      "name": "backend",
      "image": "123456789012.dkr.ecr.us-east-1.amazonaws.com/simple-app-backend:latest",
      "essential": true,
      "portMappings": [{"containerPort": 8000, "protocol": "tcp"}],
      "secrets": [
        {
          "name": "DB_PASSWORD",
          "valueFrom": "arn:aws:secretsmanager:us-east-1:123456789012:secret:mysql/simple-app/app-password-XyZ123"
        }
      ],
      "environment": [
        {"name": "DB_USERNAME", "value": "appuser"},
        {"name": "DB_HOST", "value": "mysql.simple-app-dev.local"},
        {"name": "DB_PORT", "value": "3306"},
        {"name": "DB_NAME", "value": "simpledb"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/simple-app-backend",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "healthCheck": {
        "command": ["CMD-SHELL", "curl -f http://localhost:8000/ || exit 1"],
        "interval": 30,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 10
      }
    }
  ]
}
```

### Frontend Service

```json
{
  "family": "simple-app-frontend",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "arn:aws:iam::123456789012:role/ecsTaskExecutionRole",
  "containerDefinitions": [
    {
      "name": "frontend",
      "image": "123456789012.dkr.ecr.us-east-1.amazonaws.com/simple-app-frontend:latest",
      "essential": true,
      "portMappings": [{"containerPort": 80, "protocol": "tcp"}],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/simple-app-frontend",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "healthCheck": {
        "command": ["CMD-SHELL", "curl -f http://localhost/health || exit 1"],
        "interval": 30,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 10
      }
    }
  ]
}
```

---

## Key Components

### 1. EFS for MySQL Persistence
- MySQL data stored on EFS (`/var/lib/mysql`)
- Survives container restarts
- Multi-AZ replication
- Enable backups for production

### 2. Service Discovery
- AWS Cloud Map for DNS-based discovery
- Backend connects to `mysql.<namespace>.local`
- No hardcoded IPs

### 3. Security Groups
- **MySQL**: Allow 3306 from Backend SG only
- **Backend**: Allow 8000 from ALB SG only
- **Frontend**: Allow 80 from ALB SG only
- **ALB**: Allow 80/443 from internet

### 4. Logging
- All services log to CloudWatch
- Structured logging in backend
- 7-day retention (configurable)

---

## Deployment

### Option 1: Using Terraform (Recommended)

See `../infrastructure/README.md` for complete infrastructure deployment.

---

## Monitoring

```bash
# View logs
aws logs tail /ecs/simple-app-mysql --follow
aws logs tail /ecs/simple-app-backend --follow
aws logs tail /ecs/simple-app-frontend --follow

# Check service health
aws ecs describe-services \
  --cluster simple-app-cluster \
  --services mysql backend frontend

# ECS Exec into container
aws ecs execute-command \
  --cluster simple-app-cluster \
  --task <task-id> \
  --container backend \
  --interactive \
  --command "/bin/bash"
```

---

## Important Considerations

### ⚠️ MySQL High Availability
- Run only 1 MySQL task (no multi-writer support)
- Use EFS for data persistence
- Consider Aurora Serverless for production HA

### ⚠️ Data Backup
- Enable EFS automatic backups
- Manual backup: `mysqldump` via ECS Exec
- Test restore procedures

### ⚠️ Performance
- EFS has different performance modes
- Monitor EFS metrics in CloudWatch
- Consider provisioned throughput for production

### ⚠️ Security
- Never hardcode passwords
- Rotate secrets regularly
- Use VPC endpoints for Secrets Manager
- Enable CloudTrail for audit logging

---

## Cost Optimization

- **Right-size containers**: Start small, scale up
- **Fargate Spot**: Use for dev/test environments
- **EFS Lifecycle**: Move infrequent data to IA storage
- **Log retention**: Set appropriate retention periods
- **Single MySQL task**: No need for replicas initially

---

## Troubleshooting

### Services not starting
```bash
# Check logs
aws logs tail /ecs/simple-app-backend --follow

# Check task stopped reason
aws ecs describe-tasks --cluster simple-app-cluster --tasks <task-id>
```

### Cannot connect to MySQL
- Verify service discovery: `aws servicediscovery list-services`
- Check security groups allow traffic
- Verify MySQL task is running

### ALB health checks failing
```bash
# Check target health
aws elbv2 describe-target-health --target-group-arn <arn>

# Verify health check endpoint works
aws ecs execute-command ... --command "curl http://localhost:8000/"
```

### Secrets not injected
- Check Task Execution Role has `secretsmanager:GetSecretValue`
- Verify secret ARN includes the suffix (e.g., `-AbCdEf`)
- Check CloudWatch logs for permission errors

---

## Migration to RDS (Future)

When ready to migrate to managed RDS:
1. Create RDS MySQL instance
2. Export data: `mysqldump -u root -p simpledb > backup.sql`
3. Import to RDS: `mysql -h rds-endpoint -u admin -p simpledb < backup.sql`
4. Update backend `DB_HOST` to RDS endpoint
5. Decommission MySQL ECS service

---

## Additional Resources

- Infrastructure: `../infrastructure/README.md`
- CI/CD Pipeline: `../.github/workflows/ecs-full-demo/README.md`
- Deployment Scripts: `./deployment-examples/`
