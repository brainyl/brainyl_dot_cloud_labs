
If you've mastered Docker fundamentals (see [Complete Introduction to Docker for DevOps Engineers](./complete-introduction-docker-devops-engineers.md)), you know how to build and run individual containers. But real applications need databases, message queues, reverse proxies, and multiple services working together. Starting each service manually with `docker run` becomes unmanageable fast.

The ultimate goal is hosting Ghost CMS on AWS with production-grade infrastructure—EC2 instances, RDS databases, CloudFront distributions, and ALBs. Before deploying to the cloud, you need a reliable local development environment that mirrors your production stack. Docker Compose solves this by defining your entire stack in a single YAML file. You declare services, their dependencies, networks, volumes, and environment variables, then start everything with one command.

This guide starts locally: you'll build a multi-service stack with Ghost CMS, MySQL, MailHog for email testing, and Caddy as a reverse proxy. You'll learn service dependencies, health checks, volume management, and the commands DevOps engineers use daily. In a subsequent post, we'll deploy this same stack to AWS with production-grade infrastructure.

## What You'll Build

You'll host a complete Ghost CMS stack locally with Docker Compose:

1. **Ghost CMS** application server (the main application)
2. **MySQL 8** database with persistent storage for Ghost content
3. **MailHog** email testing service for development email workflows
4. **Caddy** reverse proxy with HTTPS termination

Here's the architecture:

```
┌─────────────────────────────────────────────────────────┐
│                    Docker Compose Stack                  │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  ┌──────────┐      ┌──────────┐      ┌──────────┐     │
│  │  Caddy   │ ────▶│  Ghost   │ ────▶│   MySQL  │     │
│  │  :443    │      │  :2368    │      │  :3306   │     │
│  └──────────┘      └──────────┘      └──────────┘     │
│         │                │                              │
│         │                └──────────┐                   │
│         │                           │                   │
│         │                    ┌──────────┐              │
│         │                    │ MailHog  │              │
│         │                    │  :8025   │              │
│         │                    └──────────┘              │
│         │                                                │
└─────────┼────────────────────────────────────────────────┘
          │
          ▼
    Host Machine
    localhost:443, :80, :2368, :8025
```

| Component | Purpose | Port |
|-----------|---------|------|
| **MySQL 8** | Persistent database for Ghost content | 3306 |
| **MailHog** | Email testing (captures SMTP traffic) | 8025 |
| **Ghost CMS** | Content management system | 2368 |
| **Caddy** | Reverse proxy with automatic HTTPS | 80, 443 |

## Prerequisites

Before starting, ensure you have:

- **Docker Desktop** installed and running ([macOS](https://docs.docker.com/desktop/install/mac-install/), [Windows](https://docs.docker.com/desktop/install/windows-install/), [Linux](https://docs.docker.com/desktop/install/linux-install/))
- **Docker Compose** (included with Docker Desktop)
- **Basic understanding of Docker** (images, containers, Dockerfiles) — see [Complete Introduction to Docker for DevOps Engineers](./complete-introduction-docker-devops-engineers.md) if needed
- **15–20 minutes** to complete the tutorial

💡 **Tip:** Docker Compose is included with Docker Desktop. If you're on Linux without Desktop, install it separately: `sudo apt-get install docker-compose-plugin`.

**Cost estimate:** This runs entirely locally. No cloud costs. Docker Desktop free tier is sufficient.

## Why Docker Compose Exists

Running a multi-service application with raw `docker run` commands means:

- Managing multiple terminal windows
- Remembering complex port mappings and environment variables
- Manually creating networks and volumes
- Coordinating startup order
- Copying long command strings between environments

Docker Compose replaces this with a declarative YAML file. You define what you want, and Compose figures out how to start it. The same `docker-compose.yml` works on your laptop, CI/CD, and staging environments.

Key benefits:

1. **Single command startup:** `docker compose up` starts everything
2. **Service dependencies:** Compose waits for databases to be healthy before starting apps
3. **Network isolation:** Services communicate via service names (e.g., `db:3306`)
4. **Volume management:** Persistent data survives container restarts
5. **Environment consistency:** Same stack runs identically everywhere 

## Core Concepts: Services, Networks, and Volumes

Understanding these three concepts is essential:

### Services

A **service** is a container definition in your `docker-compose.yml`. Each service gets a name (e.g., `db`, `ghost`), an image or build context, ports, environment variables, and dependencies.

Services can reference each other by name. When Ghost connects to `db:3306`, Docker's internal DNS resolves `db` to the MySQL container's IP address.

### Networks

Docker Compose creates a **default network** for your stack. All services join this network automatically and can communicate using service names.

You can create custom networks for isolation (e.g., a frontend network and a backend network), but the default network is sufficient for most local development stacks.

### Volumes

**Volumes** persist data beyond container lifecycles. When you delete a container, its filesystem is destroyed unless data lives in a volume.

Docker Compose supports two volume types:

- **Named volumes:** Managed by Docker (e.g., `db_data:/var/lib/mysql`)
- **Bind mounts:** Map host directories into containers (e.g., `./ghost-content:/var/lib/ghost/content`)

## Anatomy of a docker-compose.yml

Let's build a production-ready `docker-compose.yml` step by step. Create a project directory:

```bash
mkdir local
cd local
```

Create the complete `docker-compose.yml`:

```yaml
version: "3.8"

services:
  db:
    image: mysql:8
    restart: unless-stopped
    ports:
      - "3306:3306"
    environment:
      MYSQL_DATABASE: ghost
      MYSQL_USER: ghost
      MYSQL_PASSWORD: ghostpass
      MYSQL_ROOT_PASSWORD: rootpass
    volumes:
      - db_data:/var/lib/mysql
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h localhost -u$MYSQL_USER -p$MYSQL_PASSWORD || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5

  mailhog:
    image: mailhog/mailhog:v1.0.1
    restart: unless-stopped
    ports:
      - "8025:8025"

  ghost:
    image: ghost:6
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
      mailhog:
        condition: service_started
    env_file:
      - ./.env.local
    ports:
      - "2368:2368"
    environment:
      url: https://localhost
      database__client: mysql
      database__connection__host: db
      database__connection__user: ghost
      database__connection__password: ghostpass
      database__connection__database: ghost
      mail__transport: SMTP
      mail__options__host: mailhog
      mail__options__port: 1025
      mail__options__secure: "false"
      mail__from: "Brainyl Cloud <noreply@brainyl.cloud>"
    healthcheck:
      test:
        - CMD
        - node
        - -e
        - >-
          require('http').get('http://127.0.0.1:2368/ghost/api/admin/site/',
          (res) => {
            if (res.statusCode >= 400) {
              process.exit(1);
            }
            res.resume();
            res.on('end', () => process.exit(0));
          }).on('error', () => process.exit(1));
      interval: 10s
      timeout: 5s
      retries: 5
    volumes:
      - ./ghost-content:/var/lib/ghost/content

  caddy:
    image: caddy:2.8
    restart: unless-stopped
    depends_on:
      ghost:
        condition: service_healthy
    ports:
      - "443:443"
      - "80:80"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./certs:/etc/caddy/certs:ro
      - ./media:/srv/media:ro
      - ../content:/srv/content:ro
    environment:
      XDG_CONFIG_HOME: /config
      XDG_DATA_HOME: /data

volumes:
  db_data:
    driver: local
```

### Key docker-compose.yml Sections Explained

| Section | Purpose | Example |
|---------|---------|--------|
| `version` | Compose file format version | `"3.8"` |
| `services` | Container definitions | `db:`, `ghost:`, `caddy:` |
| `image` | Pre-built image to use | `mysql:8`, `ghost:6` |
| `build` | Build from Dockerfile | `build: ./webhook_service` |
| `ports` | Host:container port mapping | `"3306:3306"` |
| `environment` | Runtime environment variables | `MYSQL_DATABASE: ghost` |
| `env_file` | Load variables from file | `- ./.env.local` |
| `volumes` | Persistent storage | `db_data:/var/lib/mysql` |
| `depends_on` | Startup order and health checks | `db: condition: service_healthy` |
| `healthcheck` | Container health verification | `test: ["CMD-SHELL", "..."]` |
| `restart` | Restart policy | `unless-stopped` |

### Service Dependencies and Health Checks

The `depends_on` directive controls startup order:

```yaml
depends_on:
  db:
    condition: service_healthy
  mailhog:
    condition: service_started
```

- `service_started`: Wait for the container to start (doesn't verify it's ready)
- `service_healthy`: Wait for the health check to pass (recommended for databases)

Ghost waits for MySQL to be healthy before starting. This prevents connection errors during initialization.

### Environment Variables: Inline vs Files

You can set environment variables two ways:

**Inline (for non-sensitive values):**
```yaml
environment:
  url: https://localhost
  database__client: mysql
```

**From file (for secrets and per-environment config):**
```yaml
env_file:
  - ./.env.local
```

Create `.env.local`:

```bash
# Ghost configuration
GHOST_URL=https://localhost
GHOST_ADMIN_KEY=your-admin-key-here

# Optional: API keys, webhook secrets, etc.
API_KEY=test-key-123
```

⚠️ **Caution:** Add `.env.local` to `.gitignore`. Never commit secrets to version control.

### Volume Types: Named vs Bind Mounts

**Named volumes** (managed by Docker):
```yaml
volumes:
  - db_data:/var/lib/mysql
```

Data persists in Docker's storage location. Use for databases and data that should survive container recreation.

**Bind mounts** (host directories):
```yaml
volumes:
  - ./ghost-content:/var/lib/ghost/content
  - ./Caddyfile:/etc/caddy/Caddyfile:ro
```

Maps host directories into containers. The `:ro` suffix makes it read-only. Use for configuration files and development code that you edit on the host.

## Step 1: Create Supporting Files

Create the directory structure and supporting files:

```bash
mkdir -p ghost-content certs media
```

Generate TLS certificates for localhost using `mkcert`:

```bash
# Install mkcert (macOS)
brew install mkcert

# Install the local CA (trusts certificates generated by mkcert)
mkcert -install

# Generate certificates for localhost (includes 127.0.0.1 for browser trust)
mkcert -cert-file certs/localhost.pem \
       -key-file certs/localhost-key.pem \
       localhost 127.0.0.1
```

💡 **Tip:** For Linux and Windows, download mkcert from [mkcert.dev](https://mkcert.dev) and follow the installation instructions for your platform.

Create `.env.local`:

```bash
cat > .env.local <<EOF
# Ghost Admin API Key (get this after first Ghost login)
GHOST_ADMIN_KEY=

# Optional: API keys, webhook secrets
API_KEY=dev-key-123
EOF
```

Create the `Caddyfile` for the reverse proxy with HTTPS and media handling:

```bash
cat > Caddyfile <<'EOF'
{
    auto_https off
}

https://localhost {
    tls /etc/caddy/certs/localhost.pem /etc/caddy/certs/localhost-key.pem
    
    # Serve media files
    handle_path /media/* {
        root * /srv/media
        file_server
    }
    
    reverse_proxy ghost:2368 {
        header_up X-Forwarded-Proto https
    }
}
EOF
```

Create `.gitignore`:

```bash
cat > .gitignore <<EOF
.env.local
ghost-content/
certs/
*.log
EOF
```

## Step 2: Access Ghost Admin

Once the stack is running (Step 3), configure Ghost admin and retrieve the API key.

Open Ghost admin in your browser:

```bash
open http://localhost:2368/ghost
```

Create an admin account, then retrieve the Admin API key:

1. Go to Settings → Integrations → Add custom integration
2. Copy the Admin API Key
3. Update `.env.local`:

```bash
echo "GHOST_ADMIN_KEY=your-key-here" >> .env.local
```

Restart Ghost to load the new environment variable:

```bash
docker compose restart ghost
```

## Essential Docker Compose Commands

Here are the commands you'll use daily for local development:

### Starting and Stopping

```bash
# start all services in detached mode (background)
docker compose up -d

# start and view logs in foreground
docker compose up

# start specific services only
docker compose up db mailhog

# stop all services
docker compose down

# stop and remove volumes (deletes database data)
docker compose down -v

# restart a specific service
docker compose restart ghost

# stop all services without removing containers
docker compose stop
```

### Viewing Status and Logs

```bash
# list running services
docker compose ps

# view logs for all services
docker compose logs

# follow logs in real-time
docker compose logs -f

# view logs for a specific service
docker compose logs ghost

# view last 100 lines for a service
docker compose logs --tail=100 ghost

# view logs since a specific time
docker compose logs --since 10m ghost
```

### Executing Commands

```bash
# execute a command in a running service
docker compose exec db mysql -u ghost -pghostpass ghost

# open an interactive shell
docker compose exec ghost /bin/bash

# run a one-off command in a new container
docker compose run --rm ghost node --version

# run a command in a service that's not running
docker compose run db mysql -u root -prootpass -e "SHOW DATABASES;"
```

### Building and Rebuilding

```bash
# build images defined with 'build:' directive
docker compose build

# rebuild without cache
docker compose build --no-cache

# build and start
docker compose up --build

# rebuild a specific service
docker compose build ghost
```

### Inspecting and Debugging

```bash
# show service configuration
docker compose config

# validate compose file syntax
docker compose config --quiet

# show resource usage
docker compose top

# view service IP addresses
docker compose ps --format json | jq '.[] | {name: .Name, ip: .Networks}'
```

### Cleanup

```bash
# remove stopped containers
docker compose rm

# remove containers and volumes
docker compose down -v

# remove unused images created by compose
docker compose down --rmi local

# remove everything (containers, volumes, networks)
docker compose down -v --remove-orphans
```

💡 **Tip:** Use `docker compose logs -f` to debug startup issues. Watch for health check failures and connection errors.

## Step 3: Start the Stack

Start all services:

```bash
docker compose up -d
```

Watch the startup process:

```bash
docker compose logs -f
```

You'll see:

1. MySQL starting and initializing the database
2. MailHog starting on port 8025
3. Ghost waiting for MySQL health check, then starting
4. Caddy waiting for Ghost health check, then starting

✅ **Result:** All services should show as "healthy" or "started" in `docker compose ps`.

Now that the stack is running, complete Step 2 (Access Ghost Admin) if you haven't already.

## Step 4: Verify Services

Check service status:

```bash
docker compose ps
```

Expected output:

```
NAME                IMAGE               STATUS
local-caddy-1       caddy:2.8          Up (healthy)
local-db-1          mysql:8            Up (healthy)
local-ghost-1       ghost:6            Up (healthy)
local-mailhog-1     mailhog/mailhog    Up
```

💡 **Tip:** Container names use the format `{directory-name}-{service-name}-{number}`. If your directory is named `local`, containers will be `local-caddy-1`, etc.

Test each service:

```bash
# MySQL (run command inside container)
docker compose exec db mysql -u ghost -pghostpass ghost -e "SHOW TABLES;"

# MailHog web UI
open http://localhost:8025

# Ghost API
curl http://localhost:2368/ghost/api/admin/site/

# Caddy reverse proxy (HTTPS only)
curl -k https://localhost/
```

## Step 5: Test Email with MailHog

MailHog captures all SMTP traffic from Ghost. When Ghost sends an email (e.g., password reset, member signup), it appears in MailHog's web UI.

Access MailHog:

```bash
open http://localhost:8025
```

Trigger an email from Ghost (e.g., invite a team member), then check MailHog. You'll see the email content, headers, and can test email workflows without a real SMTP server.

## Step 6: Work with Volumes

Ghost content persists in `./ghost-content`:

```bash
ls -la ghost-content/
```

Database data persists in the `db_data` named volume:

```bash
# inspect the volume (volume name is {directory-name}_db_data)
docker volume inspect local_db_data

# backup the database
docker compose exec db mysqldump -u root -prootpass ghost > backup.sql

# restore from backup
docker compose exec -T db mysql -u root -prootpass ghost < backup.sql
```

## Common Development Workflows

### Hot Reload Development

Mount your source code as a bind mount for live editing:

```yaml
ghost:
  volumes:
    - ./ghost-content:/var/lib/ghost/content
    - ./src:/app/src  # your source code
```

Changes on the host appear immediately in the container.

### Debugging a Failing Service

View logs for a specific service:

```bash
docker compose logs ghost
```

Execute commands in the container:

```bash
docker compose exec ghost /bin/bash
# inside container
env | grep database
```

### Resetting the Stack

Remove everything and start fresh:

```bash
docker compose down -v
docker compose up -d
```

This deletes all data. Use with caution.

## Cleanup

Stop and remove all services, volumes, and the project directory:

```bash
# Stop and remove all services
docker compose down

# Remove volumes (deletes database data)
docker compose down -v

# Remove the project directory
cd ..
rm -rf local
```

## Production Considerations

This guide focused on local development, but Docker Compose also runs in production for small deployments:

**Networking:**

- Use reverse proxies (Caddy, Traefik, Nginx) for HTTPS termination
- Expose only necessary ports (don't expose database ports publicly)
- Use Docker networks for service isolation

**Security:**

- Never commit `.env` files with secrets
- Use Docker secrets or external secret managers (AWS Secrets Manager, HashiCorp Vault)
- Run containers as non-root users
- Scan images for vulnerabilities

**Scaling:**

- Docker Compose doesn't scale horizontally (use Docker Swarm or Kubernetes for that)
- For production, consider ECS, EKS, or managed container services
- Use load balancers for high availability

**Monitoring:**

- Add health checks to all services
- Use `restart: unless-stopped` for resilience
- Integrate with logging (CloudWatch, Datadog, ELK stack)
- Monitor resource usage with `docker stats`

**Data Management:**

- Backup volumes regularly
- Use named volumes for production data
- Test restore procedures
- Consider managed databases (RDS, Aurora) instead of containerized databases

## What's Next

You've learned how to host Ghost CMS locally with Docker Compose:

- **Multi-service orchestration:** Define services, dependencies, and health checks
- **Volume management:** Persistent data with named volumes and bind mounts
- **Environment configuration:** Inline variables and `.env` files
- **Essential commands:** Start, stop, logs, exec, and debugging workflows

Now that you have Ghost CMS running locally, the next step is deploying it to AWS with production-grade infrastructure. In a follow-up post, we'll cover:

**AWS deployment:**
- Deploying Ghost CMS to AWS using Terraform
- Using RDS for MySQL instead of containerized databases
- Setting up CloudFront and ALB for production traffic
- Configuring EKS or ECS for container orchestration

**Related topics:**
- [EKS Auto Mode Quick Bootstrap](./eks-auto-mode-quick-bootstrap-terraform.md) — Run containers on Kubernetes
- [Stop Using Access Keys in GitHub Actions](./stop-using-access-keys-github-actions-aws.md) — Secure container builds
- Multi-file Docker Compose composition for environment-specific configurations

## Conclusion

You've successfully set up Ghost CMS locally with Docker Compose. The stack runs with a single command and includes all the services Ghost needs: MySQL for content storage, MailHog for email testing, and Caddy for HTTPS termination.

Key takeaways:

- **Service orchestration:** Dependencies, health checks, and startup order ensure Ghost starts only after MySQL is ready
- **Volume management:** Named volumes persist Ghost content and database data across container restarts
- **Environment configuration:** `.env` files keep secrets out of version control
- **Essential commands:** `docker compose up`, `down`, `logs`, and `exec` cover most development workflows
- **Local development foundation:** This same stack structure will translate to AWS deployment

The `docker-compose.yml` you built runs Ghost CMS locally and serves as the foundation for production deployment. The follow-up guide walks through deploying Ghost to AWS with CloudFront, Application Load Balancer, EC2 Auto Scaling, and Aurora Serverless.

Ready to deploy Ghost CMS to AWS? Check out [Take Ghost CMS to Production on AWS: CloudFront, ALB, and Aurora Serverless](./ghost-production-aws-cloudfront-alb-aurora.md), or review [Complete Introduction to Docker for DevOps Engineers](./complete-introduction-docker-devops-engineers.md) if you need container fundamentals.
