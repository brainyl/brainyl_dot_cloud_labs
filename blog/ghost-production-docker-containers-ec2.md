
We've made progress deploying Ghost CMS using several AWS services—CloudFront, ALB, Auto Scaling Groups, and Aurora. In [Take Ghost CMS to Production on AWS: CloudFront, ALB, and Aurora Serverless](./ghost-production-aws-cloudfront-alb-aurora.md) and [Ghost CMS on AWS with NAT Instances: Cut Egress Costs by 70%](./ghost-production-aws-nat-instances.md), Ghost ran directly on the OS with systemd managing the service.

One thing you'll notice is that we used `ghost install --process systemd` for creating the Ghost service in the EC2 instances. The decision to go this route is deliberate. Sometimes you find yourself in environments where teams already use orchestration on top of the OS (like ECS, Kubernetes, or Nomad), but other times you work with legacy systems that run directly on the OS using something like systemd.

systemd is a whole Linux subject on its own and would have to be studied separately. But with systemd, you can run several commands to operate your services:

- `systemctl status ghost_<sitename>` - View the status of the Ghost service
- `systemctl restart ghost_<sitename>` - Restart the Ghost service
- `systemctl start ghost_<sitename>` - Start the Ghost service
- `systemctl stop ghost_<sitename>` - Stop the Ghost service
- `systemctl enable ghost_<sitename>` - Enable service to start on boot
- `systemctl disable ghost_<sitename>` - Disable service from starting on boot
- `journalctl -u ghost_<sitename>` - Check logs from the service
- `journalctl -u ghost_<sitename> -f` - Follow logs in real-time

To further explore working at a lower level of orchestration, we can run the Ghost service as a Docker container. This is lower level since we would need to take an EC2 machine, install Docker on it, run our service, and then expose it outside the machine. Here we're not relying on the several already-made options to run Docker workloads, which we'll be seeing as we progress in this series.

If you're new to Docker or need a refresher, check out [Complete Introduction to Docker for DevOps Engineers](./complete-introduction-docker-devops-engineers.md) first. That post covers containers, images, volumes, networking, and the core concepts you'll need here.

## What You'll Build

The exact same production Ghost deployment from previous posts, but with Docker containers instead of systemd:

**Architecture:**

```
CloudFront (us-east-1)
       ↓
Application Load Balancer (us-west-2)
       ↓
Auto Scaling Group (Ghost EC2 instances in private subnets)
    → Each instance runs Ghost in a Docker container
       ↓
Aurora Serverless v2 (database subnets)
```

| Component | Change from Previous Posts |
|-----------|---------------------------|
| VPC | No change |
| NAT (Gateway or Instance) | No change |
| ALB | No change |
| ASG | **EC2 userdata installs Docker instead of Ghost-CLI** |
| Aurora | No change |
| CloudFront | No change |
| ACM | No change |

**The only difference:** Ghost runs inside a Docker container managed by Docker Engine instead of a native systemd service managed by Ghost-CLI.

## Prerequisites

- **AWS account** with appropriate permissions
- **Terraform** ≥ v1.13.4
- **AWS CLI** v2 configured
- **Docker Desktop** ≥ v4.49 (for local testing if needed)
- **Domain name** with DNS access
- **Region**: `us-west-2` (adjust as needed)

---

## Why Docker Instead of systemd?

In the previous posts, Ghost installed directly on the OS with systemd managing the process. Now we're running Ghost inside a Docker container. Why does this matter?

### systemd Approach (Previous Posts)

**Benefits:**

- Simple and direct—Ghost runs as a native Linux service
- No container runtime overhead
- Fewer moving parts to debug
- systemd handles service lifecycle (start, stop, restart)
- Built into every modern Linux distribution

**Trade-offs:**

- Ghost files and dependencies exist on the host filesystem
- Harder to replicate the exact environment across instances
- Package conflicts can occur (Node.js versions, system libraries)
- Updates require installing packages directly on the OS

**Best for:**

- Simple deployments where containers aren't needed
- Legacy environments that don't use containers
- Teams without Docker experience

### Docker Approach (This Post)

**Benefits:**

- Consistent environment—same Ghost image runs everywhere
- Isolation—Ghost and its dependencies are contained
- Version control—Docker image tags pin exact Ghost versions
- Easier rollbacks—swap image tags instead of reinstalling packages
- Portable—same container runs locally, in EC2, or in ECS later
- Volume mounts separate data from the application layer

**Trade-offs:**

- Additional layer to manage (Docker daemon)
- Container runtime uses some CPU/memory
- More concepts to learn (images, volumes, networks)
- Debugging requires container-specific tools

**Best for:**

- Teams already using Docker
- Environments moving toward container orchestration (ECS, EKS)
- Deployments requiring environment consistency
- Learning path toward managed container services

### Why This Matters for the Ghost Series

We're building toward managed container services in future posts. Running Docker on EC2 is the middle step—you understand how containers work at the infrastructure level before letting AWS abstract that away.

This approach also reflects real-world environments. Not every team runs Kubernetes or ECS. Many production systems run Docker containers directly on EC2 instances with simple orchestration (or none at all). Understanding this level helps you troubleshoot and operate these systems.

---

## Infrastructure: Use Previous Posts

The infrastructure is identical to previous posts. You can use either:

**Option A: NAT Gateways (simpler, higher cost)**

Use the complete infrastructure from [Take Ghost CMS to Production on AWS: CloudFront, ALB, and Aurora Serverless](./ghost-production-aws-cloudfront-alb-aurora.md):
- VPC with NAT Gateways
- ALB, ASG, Aurora, CloudFront
- All supporting resources (security groups, IAM roles, ACM certificates)

**Option B: NAT Instances (cost-optimized, recommended)**

Use the complete infrastructure from [Ghost CMS on AWS with NAT Instances](./ghost-production-aws-nat-instances.md):
- VPC with NAT Instances
- Same ALB, ASG, Aurora, CloudFront setup
- 70-90% lower egress costs

**What you'll change:** Only the `userdata.sh` file. Everything else stays the same.

Copy all the Terraform files (`terraform.tf`, `variables.tf`, `main.tf`, `outputs.tf`, `terraform.tfvars`) from either post. Then replace the `userdata.sh` file with the Docker-based version shown below.

---

## The Docker-Based Userdata Script

This is where everything changes. Instead of installing Ghost-CLI and using systemd, we install Docker and run Ghost as a container.

Below is the userdata script. Looking at the script, we start by updating the system, installing Docker and the necessary packages, and then running the Ghost service as a Docker container.

Create `userdata.sh`:


```bash
#!/bin/bash
set -e

# Add /usr/local/bin to PATH for AWS CLI
export PATH="/usr/local/bin:$PATH"

# Variables (will be replaced by Terraform templatefile)
PROJECT_NAME="${project_name}"
AWS_REGION="${aws_region}"
DOMAIN_NAME="${domain_name}"

# Update system
apt-get update
apt-get upgrade -y

# Install Docker and dependencies
apt-get install -y ca-certificates curl gnupg jq mysql-client unzip python3-pip
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Install AWS CLI v2
echo "Installing AWS CLI v2..."
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ]; then
  curl -sL https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip -o awscliv2.zip
else
  curl -sL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o awscliv2.zip
fi
unzip -q awscliv2.zip
./aws/install
rm -rf aws awscliv2.zip
aws --version

# Fetch Aurora database configuration from SSM
echo "Fetching Aurora database configuration..."
# Get region from EC2 instance metadata (IMDSv2)
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" -s)
REGION=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/placement/region)
echo "Detected region: $REGION"

# Fetch database connection details
DB_PORT=3306
DB_ENDPOINT=$(aws ssm get-parameter --name "/$PROJECT_NAME/db-host" --region $AWS_REGION --query 'Parameter.Value' --output text)
DB_NAME=$(aws ssm get-parameter --name "/$PROJECT_NAME/db-name" --region $AWS_REGION --query 'Parameter.Value' --output text)
DB_USERNAME=$(aws ssm get-parameter --name "/$PROJECT_NAME/db-username" --region $AWS_REGION --query 'Parameter.Value' --output text)

SECRET_ARN=$(aws ssm get-parameter --name "/$PROJECT_NAME/db-password" --region $AWS_REGION --query 'Parameter.Value' --output text)
DB_PASSWORD=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --region $AWS_REGION --query 'SecretString' --output text | jq -r '.password')

# Wait for Aurora to be ready (retry for up to 5 minutes)
echo "Testing database connectivity..."
MAX_RETRIES=30
RETRY_COUNT=0

until mysql -h "$DB_ENDPOINT" -P "$DB_PORT" -u "$DB_USERNAME" -p"$DB_PASSWORD" -e "SELECT 1;" 2>/dev/null || [ $RETRY_COUNT -eq $MAX_RETRIES ]; do
  echo "Waiting for Aurora to be ready... (attempt $((RETRY_COUNT+1))/$MAX_RETRIES)"
  sleep 10
  RETRY_COUNT=$((RETRY_COUNT+1))
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
  echo "ERROR: Cannot connect to Aurora after $((MAX_RETRIES*10)) seconds"
  echo "DB_ENDPOINT: $DB_ENDPOINT"
  echo "DB_PORT: $DB_PORT"
  echo "DB_USERNAME: $DB_USERNAME"
  echo "Please verify:"
  echo "  1. Security group allows connections from this EC2 instance"
  echo "  2. Database credentials in Secrets Manager are correct"
  echo "  3. Aurora cluster is in 'available' state"
  exit 1
fi

echo "Successfully connected to Aurora database"

# Create Ghost database if it doesn't exist
echo "Ensuring Ghost database exists..."
mysql -h "$DB_ENDPOINT" -P "$DB_PORT" -u "$DB_USERNAME" -p"$DB_PASSWORD" -e "CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || {
  echo "WARNING: Failed to create database (may already exist)"
}

# Create directory for Ghost data
mkdir -p /var/lib/ghost

# Configure Ghost URL
GHOST_URL="https://${domain_name}"
echo "Ghost URL: $GHOST_URL"

# Run Ghost container with Aurora MySQL configuration (SSL enabled)
echo "Starting Ghost container..."

# Build docker run command with proper array handling
docker run -d \
  --name ghost \
  --restart always \
  -p 2368:2368 \
  -v /var/lib/ghost/content:/var/lib/ghost/content \
  -e url="$GHOST_URL" \
  -e database__client=mysql \
  -e database__connection__host="$DB_ENDPOINT" \
  -e database__connection__port="$DB_PORT" \
  -e database__connection__user="$DB_USERNAME" \
  -e database__connection__password="$DB_PASSWORD" \
  -e database__connection__database="$DB_NAME" \
  -e database__connection__ssl__rejectUnauthorized=false \
  ghost:6

echo "Ghost deployment complete (Docker container with Aurora MySQL)."
```


---

## What Changed in the Userdata Script?

Looking at the script, here's what's different from the systemd approach:

**Removed (systemd approach):**

- Node.js installation from NodeSource
- Ghost-CLI installation via npm
- `ghost install` command with all its flags
- Ghost config file creation
- systemd service setup

**Added (Docker approach):**

- Docker CE installation (including Docker Engine, CLI, containerd, and plugins)
- Docker repository setup with GPG keys
- `docker run` command with environment variables
- Volume mount for `/var/lib/ghost/content` (Ghost content directory)
- Container restart policy (`--restart always`)

**Unchanged:**

- AWS CLI installation (needed for SSM and Secrets Manager)
- Database credential fetching from SSM/Secrets Manager
- Database connectivity testing
- Database creation if it doesn't exist

The Ghost configuration that previously lived in `config.production.json` now comes from Docker environment variables (`-e url=...`, `-e database__client=...`, etc.). Ghost's official Docker image reads these environment variables and generates the config file automatically inside the container.

The key here is we're replacing the systemd approach with Docker for running our service.

---

## systemd vs Docker: Operational Differences

Here's what changes day-to-day when you switch from systemd to Docker:

| Task | systemd Command | Docker Command |
|------|-----------------|----------------|
| **View service status** | `systemctl status ghost_<sitename>` | `docker ps` or `docker inspect ghost` |
| **View logs** | `journalctl -u ghost_<sitename>` | `docker logs ghost` or `docker logs -f ghost` |
| **Restart service** | `systemctl restart ghost_<sitename>` | `docker restart ghost` |
| **Stop service** | `systemctl stop ghost_<sitename>` | `docker stop ghost` |
| **Start service** | `systemctl start ghost_<sitename>` | `docker start ghost` |
| **Check config** | `cat /var/www/ghost/config.production.json` | `docker exec ghost cat /var/lib/ghost/config.production.json` |

The Docker approach trades systemd's integrated service management for container portability and isolation.

---

## Deploy

With your infrastructure files from the previous post and the new Docker-based `userdata.sh`, deploy:


```bash
terraform init
terraform validate
terraform plan
terraform apply
```


**Wait time:** 10-15 minutes for:
- VPC, subnets, NAT (Gateway or Instance)
- Aurora Serverless v2 cluster
- ALB and target group
- EC2 instances to launch and run userdata
- CloudFront distribution to deploy

---

## Validate Docker Container is Running

### Check ALB Target Health

```bash
# Check if EC2 instances are healthy in the target group
aws elbv2 describe-target-health \
  --target-group-arn $(aws elbv2 describe-target-groups \
    --names ghost-blog-tg \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text) \
  --query 'TargetHealthDescriptions[*].[Target.Id,TargetHealth.State]' \
  --output table
```

✅ **Expected:** Both instances show `healthy` state.

### SSH into EC2 Instance via Session Manager

```bash
# Get Ghost instance ID
GHOST_INSTANCE=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=ghost-blog" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

# Start session
aws ssm start-session --target $GHOST_INSTANCE
```

### Check Docker Container Status

Once connected to the instance:

```bash
# View running containers
docker ps

# Expected output:
# CONTAINER ID   IMAGE     COMMAND                  CREATED         STATUS         PORTS                    NAMES
# abc123def456   ghost:6   "docker-entrypoint.s…"   5 minutes ago   Up 5 minutes   0.0.0.0:2368->2368/tcp   ghost

# Check container logs
docker logs ghost

# Follow logs in real-time
docker logs -f ghost

# Check container details
docker inspect ghost

# Check Ghost version
docker exec ghost ghost version
```

✅ **Expected:** Container is running, logs show Ghost started successfully, no database connection errors.

### Test Ghost is Responding

```bash
# Test from inside the EC2 instance
curl -I http://localhost:2368

# Expected: HTTP 301 or 200 response

# Test ALB endpoint (from your local machine)
curl -I http://$(terraform output -raw alb_dns_name)

# Test CloudFront endpoint (after DNS propagation)
curl -I https://lab.brainyl.cloud
```

✅ **Expected:** All endpoints return HTTP responses.

---

## Docker Operations

Now that Ghost runs in Docker, you use Docker commands instead of systemd commands.

### View Container Logs

```bash
# View all logs
docker logs ghost

# Follow logs in real-time (like journalctl -f)
docker logs -f ghost

# View last 100 lines
docker logs --tail 100 ghost

# View logs with timestamps
docker logs -t ghost
```

### Restart Ghost

```bash
# Restart the container (similar to systemctl restart)
docker restart ghost

# Stop and start separately
docker stop ghost
docker start ghost
```

### Access Ghost Container Shell

```bash
# Open a bash shell inside the container
docker exec -it ghost /bin/bash

# Once inside, you can:
cd /var/lib/ghost
ls -la
cat config.production.json
exit
```

### Update Ghost Version

With Docker, you update Ghost by pulling a new image and recreating the container:

```bash
# Pull a specific Ghost version
docker pull ghost:6.1.0

# Stop and remove the old container
docker stop ghost
docker rm ghost

# Start new container with the new image
docker run -d \
  --name ghost \
  --restart always \
  -p 2368:2368 \
  -v /var/lib/ghost/content:/var/lib/ghost/content \
  -e url="https://lab.brainyl.cloud" \
  -e database__client=mysql \
  -e database__connection__host="<DB_HOST>" \
  -e database__connection__port="3306" \
  -e database__connection__user="<DB_USER>" \
  -e database__connection__password="<DB_PASS>" \
  -e database__connection__database="ghost_production" \
  ghost:6.1.0
```

The `/var/lib/ghost/content` volume persists across container replacements—your posts, images, and themes remain intact.

### Check Container Resource Usage

```bash
# View container CPU and memory usage
docker stats ghost

# View all container details
docker inspect ghost | jq '.[0].State'
```

---

## Troubleshooting Docker Containers

### Container Won't Start

**Check container status:**

```bash
docker ps -a

# If container status is "Exited", check logs
docker logs ghost
```

**Common issues:**

- Database credentials incorrect → Check SSM parameters
- Aurora not reachable → Check security groups
- Port 2368 already in use → Stop conflicting process or change port mapping

### Container Starts but Ghost Not Accessible

**Check if port is listening:**

```bash
sudo netstat -tlnp | grep 2368

# Expected: docker-proxy listening on 0.0.0.0:2368
```

**Check ALB security group:**

```bash
# Security group must allow ALB to reach EC2 on port 2368
aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=ghost-blog-ec2-sg" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output table
```

### Database Connection Fails

**Test database connectivity from inside container:**

```bash
docker exec ghost mysql -h <DB_HOST> -u <DB_USER> -p<DB_PASS> -e "SELECT 1;"
```

If this fails, the issue is network (security groups) or credentials (Secrets Manager).

### Container Keeps Restarting

```bash
# Check container restart count
docker inspect ghost | jq '.[0].RestartCount'

# View logs to see why it's failing
docker logs ghost
```

**Common causes:**

- Ghost crashes on startup due to config errors
- Out of memory (check with `docker stats`)
- Database connection timing out

### Volume Mount Issues

Ghost stores content in `/var/lib/ghost/content` (inside the container), mapped to `/var/lib/ghost/content` on the host.

```bash
# Check volume mount
docker inspect ghost | jq '.[0].Mounts'

# Check files on host
ls -la /var/lib/ghost/content

# Check files inside container
docker exec ghost ls -la /var/lib/ghost/content
```

If files aren't appearing, the volume mount is misconfigured.
---

## Comparison: systemd vs Docker Ghost Deployment

Here's what you gain and lose by switching to Docker:

| Aspect | systemd Approach | Docker Approach |
|--------|------------------|-----------------|
| **Deployment** | Ghost-CLI installs Ghost directly on OS | Docker pulls official Ghost image |
| **Configuration** | `config.production.json` file | Environment variables |
| **Logs** | `journalctl -u ghost_<sitename>` | `docker logs ghost` |
| **Updates** | `ghost update` command | Pull new image, recreate container |
| **Service restart** | `systemctl restart ghost_<sitename>` | `docker restart ghost` |
| **Debugging** | Access files in `/var/www/ghost` | `docker exec` into container |
| **Portability** | Tied to specific OS and packages | Same container runs anywhere |
| **Isolation** | Shares OS dependencies | Isolated environment |
| **Complexity** | Simpler, fewer concepts | Additional Docker layer |
| **Path to ECS/Fargate** | Requires migration | Same container definition |

---

## Cleanup


```bash
terraform destroy
```


Terraform removes all resources from the previous posts' infrastructure.

---

## What's Next?

Running Docker on EC2 works, but you're still managing:

- EC2 instances (patching, scaling, monitoring)
- Docker daemon (updates, restarts, failures)
- Container lifecycle (health checks, restarts, rollbacks)
- Load balancer integration (target registration)

In upcoming posts, we'll explore managed container services where AWS handles more of this operational overhead. Each step reduces what you're responsible for. This post shows you what happens at the infrastructure level before those services abstract it away.

### Optimizing the Userdata Script with Custom AMIs

The userdata script in this post installs Docker, AWS CLI, and other dependencies on every EC2 instance launch. This works, but it increases instance startup time.

You can improve this by baking these dependencies into a custom Amazon Machine Image (AMI). With a custom AMI:

- Docker, AWS CLI, and system packages are pre-installed
- Instances launch faster
- Userdata script only needs to fetch credentials and start the Ghost container
- Consistent base image across all instances

If you want to explore building custom AMIs with EC2 Image Builder, check out [How to Build Custom Amazon Machine Image (AMI) with EC2 Image Builder](https://www.youtube.com/watch?v=O0uGlDy5OsA). The video walks through creating reusable base images that can significantly reduce your instance bootstrap time.

---

## Conclusion

You've deployed the same production Ghost infrastructure with Docker containers instead of systemd services. Ghost runs inside Docker on EC2 instances, connected to the same ALB, Aurora, and CloudFront setup from previous posts.

The infrastructure code is unchanged. The userdata script replaces Ghost-CLI with Docker commands. Ghost's official Docker image handles all the Node.js dependencies, package management, and configuration—you just pass environment variables.

**Key takeaways:**

- Same AWS infrastructure, different runtime (Docker vs systemd)
- Docker provides consistent environments and simpler updates (pull new image)
- Trade-off: Additional Docker layer to manage and understand
- Foundation for managed container services on AWS
- Real-world pattern: Many teams run Docker directly on EC2 before moving to orchestration platforms

Docker-on-EC2 sits between native systemd deployments and fully managed container platforms. Understanding this level helps you troubleshoot and operate these systems, even if you eventually move to managed services.

**Related posts:**

- [Take Ghost CMS to Production on AWS: CloudFront, ALB, and Aurora Serverless](./ghost-production-aws-cloudfront-alb-aurora.md) – The base infrastructure (use this for NAT Gateways)
- [Ghost CMS on AWS with NAT Instances: Cut Egress Costs by 70%](./ghost-production-aws-nat-instances.md) – Cost-optimized infrastructure (use this for NAT Instances)
- [Complete Introduction to Docker for DevOps Engineers](./complete-introduction-docker-devops-engineers.md) – Docker fundamentals
