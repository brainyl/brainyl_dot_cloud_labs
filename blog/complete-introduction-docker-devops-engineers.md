
If you've worked in DevOps or cloud engineering for more than a few months, you've encountered Docker. It's the foundation of modern container orchestration, CI/CD pipelines, and cloud-native architecture. Yet many engineers skip the fundamentals and jump straight into Kubernetes or ECS, then hit a wall when debugging container issues or optimizing builds.

This complete introduction fills that gap. You'll learn what Docker is, why it exists, and how to use it effectively in production environments. By the end, you'll build a FastAPI application, containerize it with a production-ready Dockerfile, and push it to AWS Elastic Container Registry (ECR).

This is a complete Docker introduction for engineers who ship code, not theory.

## What You'll Build

You'll work through a complete Docker workflow:

1. **Understand** the difference between images, containers, and Dockerfiles
2. **Build** a FastAPI application container with a multi-stage Dockerfile
3. **Push** your image to AWS ECR
4. **Validate** the image runs correctly

Here's the architecture:

```
Local Development → Docker Build → AWS ECR → (Future: ECS/EKS)
      ↓                  ↓              ↓
   Dockerfile      Docker Image    Container Registry
```

| Component | Purpose |
|-----------|---------|
| Docker Desktop | Local container runtime and build tool |
| Dockerfile | Blueprint for building container images |
| FastAPI App | Example Python web application |
| AWS ECR | Private container registry for storing images |
| AWS CLI | Authentication and push commands |

## Prerequisites

Before starting, you need:

- **Docker Desktop** installed ([macOS](https://docs.docker.com/desktop/install/mac-install/), [Windows](https://docs.docker.com/desktop/install/windows-install/), [Linux](https://docs.docker.com/desktop/install/linux-install/))
- **AWS account** with ECR access (we'll use `us-west-2`)
- **AWS CLI v2** configured with credentials
- **Basic Python knowledge** (for the FastAPI example)
- **10–15 minutes** to complete the tutorial

💡 **Tip:** Docker Desktop includes Docker CLI, Docker Compose, and Kubernetes. The free tier works for individual developers.

**Cost estimate:** ECR charges $0.10/GB per month for storage. This tutorial uses ~200MB, so under $0.02/month if you don't delete the image immediately.

## Why Docker Exists

Before Docker, deploying applications meant dealing with dependency conflicts, environment inconsistencies, and "works on my machine" problems. You'd ship code to staging or production, and it would fail because of a missing library, wrong Python version, or different system configuration.

Docker solves this by packaging your application and all its dependencies into a **container**—a lightweight, portable unit that runs the same way everywhere. Instead of shipping code and hoping the server has the right setup, you ship the entire runtime environment.

The key benefits:

1. **Consistency:** Same container runs identically on your laptop, CI/CD, and production
2. **Isolation:** Each container has its own filesystem, network, and process space
3. **Portability:** Build once, run anywhere (AWS, GCP, Azure, bare metal)
4. **Efficiency:** Containers share the host OS kernel, so they start in seconds and use less memory than VMs

This is why Docker became the foundation for Kubernetes, ECS, and every modern cloud platform.

## Core Concepts: Image, Container, and Dockerfile

Understanding these three concepts is essential:

### Docker Image

A Docker image is a **read-only template** that contains your application code, runtime, libraries, and dependencies. Think of it as a snapshot of a filesystem.

Images are built in **layers**. Each layer represents a change from the previous one (e.g., installing a package, copying files). Docker caches these layers, so rebuilds are fast when your changes are in the later layers, because all the earlier layers can be reused from cache.

Example: The official Python image includes the Python interpreter, standard library, and common system tools.

### Docker Container

A container is a **running instance** of an image. When you execute `docker run`, Docker creates a container from an image, adds a writable layer on top, and starts the process.

Key difference: An image is static (like a class in programming), while a container is dynamic (like an instance of that class). You can run multiple containers from the same image.

### Dockerfile

A Dockerfile is a **text file with instructions** for building an image. It defines the base image, application code, dependencies, and runtime configuration.

Example structure:

```dockerfile
FROM python:3.13-slim
WORKDIR /app
COPY . .
RUN pip install --no-cache-dir -r requirements.txt
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

The Docker engine reads this file top-to-bottom and builds the image layer by layer.

## Essential Docker Commands

Here are the commands you'll use daily as a DevOps engineer:

### Build and Run

```bash
# build an image from a Dockerfile in the current directory
docker build -t my-app:latest .

# run a container from an image
docker run -p 8000:8000 my-app:latest

# run in detached mode (background)
docker run -d -p 8000:8000 my-app:latest

# run with automatic cleanup when container stops
docker run --rm -p 8000:8000 my-app:latest

# run with environment variables
docker run -e DATABASE_URL=postgres://... my-app:latest

# run with a volume mount (for local development)
docker run -v $(pwd):/app my-app:latest

# combine options: detached, auto-remove, port mapping, env vars
docker run -d --rm -p 8000:8000 -e ENV=production my-app:latest
```

### List and Inspect

```bash
# list running containers
docker ps

# list all containers (including stopped)
docker ps -a

# list images
docker images

# inspect a container (shows full config, networking, mounts)
docker inspect <container_id>

# view container logs
docker logs <container_id>

# follow logs in real-time
docker logs -f <container_id>
```

### Execute and Debug

```bash
# execute a command in a running container
docker exec <container_id> ls /app

# open an interactive shell in a running container
docker exec -it <container_id> /bin/bash

# open a shell in a new container (useful for debugging images)
docker run -it my-app:latest /bin/bash
```

### Cleanup

```bash
# stop a running container
docker stop <container_id>

# remove a stopped container
docker rm <container_id>

# remove an image
docker rmi my-app:latest

# remove all stopped containers
docker container prune

# remove unused images
docker image prune

# remove all unused resources (containers, networks, images)
docker system prune -a
```

### Registry Operations

```bash
# tag an image for a registry
docker tag my-app:latest 123456789012.dkr.ecr.us-west-2.amazonaws.com/my-app:latest

# push an image to a registry
docker push 123456789012.dkr.ecr.us-west-2.amazonaws.com/my-app:latest

# pull an image from a registry
docker pull 123456789012.dkr.ecr.us-west-2.amazonaws.com/my-app:latest
```

💡 **Tip:** Use `docker run --rm` to automatically remove the container when it stops. This keeps your system clean during testing.

## Anatomy of a Dockerfile

A well-written Dockerfile is the foundation of fast builds, small images, and secure containers. Let's break down every major instruction using a FastAPI example.

### Complete Dockerfile Example

Create a directory for your FastAPI app:

```bash
mkdir docker-101-fastapi
cd docker-101-fastapi
```

Create `main.py`:

```python
from fastapi import FastAPI
import os

app = FastAPI()

@app.get("/")
def read_root():
    return {
        "message": "Hello from Docker 101",
        "env": os.getenv("ENV_VAR", "not set"),
        "build_arg": os.getenv("BUILD_ARG", "not set")
    }

@app.get("/health")
def health_check():
    return {"status": "healthy"}
```

Create `requirements.txt`:

```
fastapi==0.115.5
uvicorn[standard]==0.32.1
```

Now create the `Dockerfile`:

```dockerfile
# syntax=docker/dockerfile:1.5
# escape=\

# Parser directives (like syntax and escape) must appear before any other instruction
# syntax: enables BuildKit 1.5 features (heredocs, improved mounts)
# escape: changes the line continuation character (useful on Windows)

# ARG comes before FROM - it's the only instruction that can
ARG PYTHON_VERSION=3.13
ARG BASE_IMAGE=python:${PYTHON_VERSION}-slim

# You can override ARGs when building:
# docker build --build-arg PYTHON_VERSION=3.12 .

FROM ${BASE_IMAGE} AS builder

# LABEL stores image metadata following OCI image spec
LABEL org.opencontainers.image.authors="team@brainyl.cloud"
LABEL org.opencontainers.image.title="FastAPI Docker 101 Example"
LABEL org.opencontainers.image.version="1.0.0"

# RUN has two forms: shell and exec
# Shell form: processed by /bin/sh -c (allows variable expansion)
RUN echo "Building FastAPI image 🚀"

# Exec form: runs the binary directly (no shell processing)
RUN ["echo", "Using exec form"]

# Heredoc syntax keeps multi-line commands readable
# No more long chains of && and line continuation backslashes
RUN <<EOF
apt-get update
apt-get install -y --no-install-recommends \
    curl \
    iputils-ping
apt-get clean
rm -rf /var/lib/apt/lists/*
EOF

# Mount secrets during build without baking them into image layers
# BuildKit feature - secrets never appear in final image or history
RUN --mount=type=secret,id=build_secret,dst=/tmp/secret.txt \
    if [ -f /tmp/secret.txt ]; then \
        echo "Secret found, running authenticated build step"; \
    else \
        echo "No secret provided, skipping authenticated step"; \
    fi

# Build arguments - available during build only
# Warning: ARG values show up in image metadata via docker inspect
ARG BUILD_ARG=production
ARG BUILD_DATE
ARG GIT_COMMIT

# Environment variables persist into running containers
# Set Python-specific vars to improve container behavior
ENV ENV_VAR=docker-101 \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# WORKDIR creates the directory if missing and sets it as current
WORKDIR /app

# Copy dependency manifest first for layer cache optimization
# If requirements.txt doesn't change, Docker reuses this layer
COPY requirements.txt .

# Install dependencies in their own layer
RUN pip install --no-cache-dir -r requirements.txt

# Copy source code last - this layer changes most frequently
# Keeping it separate means pip install layer stays cached
COPY main.py .

# EXPOSE is documentation - tells users which port the app uses
# The actual port mapping happens at runtime with -p flag
EXPOSE 8000

# Never run production containers as root
# Create a dedicated user with minimal permissions
RUN useradd -m -u 1000 appuser && \
    chown -R appuser:appuser /app

# All subsequent commands run as this user
USER appuser

# ENTRYPOINT sets the main process - this part is fixed
ENTRYPOINT ["uvicorn"]

# CMD provides default arguments (can be completely replaced at runtime)
# Warning: Overriding replaces ALL args, not just adds to them
CMD ["main:app", "--host", "0.0.0.0", "--port", "8000"]

# Default command executed: uvicorn main:app --host 0.0.0.0 --port 8000
```

### Key Dockerfile Instructions Explained

| Instruction | Purpose | Example |
|-------------|---------|---------|
| `FROM` | Sets the base image | `FROM python:3.13-slim` |
| `ARG` | Build-time variable (can be overridden) | `ARG PYTHON_VERSION=3.13` |
| `ENV` | Runtime environment variable | `ENV PYTHONUNBUFFERED=1` |
| `WORKDIR` | Sets working directory | `WORKDIR /app` |
| `COPY` | Copies files from host to image | `COPY main.py .` |
| `RUN` | Executes command during build | `RUN pip install -r requirements.txt` |
| `EXPOSE` | Documents container port | `EXPOSE 8000` |
| `USER` | Sets the user for RUN, CMD, ENTRYPOINT | `USER appuser` |
| `ENTRYPOINT` | Executable to run when container starts | `ENTRYPOINT ["uvicorn"]` |
| `CMD` | Default arguments to ENTRYPOINT | `CMD ["main:app", "--host", "0.0.0.0"]` |

### Build Arguments vs Environment Variables

**ARG** is for build-time configuration:
- Python version, base image tag, build date
- Visible in image metadata (don't use for secrets)
- Not available in running containers

**ENV** is for runtime configuration:
- Database URLs, API keys (from secrets manager), feature flags
- Available during build AND when container runs
- Can be overridden with `docker run -e`

### Shell Form vs Exec Form

```dockerfile
# Shell form - runs with /bin/sh -c
RUN echo "Hello $USER"

# Exec form - runs directly (no shell)
RUN ["echo", "Hello"]
```

Use **exec form** for `ENTRYPOINT` and `CMD` so signals (like SIGTERM) reach your application directly. This matters for graceful shutdowns in Kubernetes and ECS.

### ENTRYPOINT vs CMD

- `ENTRYPOINT` defines the **main executable** (e.g., `uvicorn`, `node`, `python`)
- `CMD` provides **default arguments** to that executable

You can override `CMD` at runtime, but `ENTRYPOINT` is fixed (unless you use `--entrypoint`).

⚠️ **Caution:** When you override CMD, you replace the **entire** CMD, not append to it.

```bash
# Uses CMD from Dockerfile: ["main:app", "--host", "0.0.0.0", "--port", "8000"]
# Final command: uvicorn main:app --host 0.0.0.0 --port 8000
docker run my-app

# This REPLACES the entire CMD with just "main:app --reload"
# Final command: uvicorn main:app --reload
# You LOSE --host and --port (app only listens on localhost)
docker run my-app main:app --reload

# To keep the defaults AND add --reload, specify everything:
# Final command: uvicorn main:app --host 0.0.0.0 --port 8000 --reload
docker run my-app main:app --host 0.0.0.0 --port 8000 --reload
```

## Step 1: Build the FastAPI Image

Our Dockerfile uses BuildKit features (heredocs, secret mounts) via the `# syntax=docker/dockerfile:1.5` directive. Docker Desktop enables BuildKit by default, but if you're on an older setup, enable it:

```bash
export DOCKER_BUILDKIT=1
```

Build the image:

```bash
docker build -t fastapi-docker-101:latest .
```

To pass build arguments:

```bash
docker build \
  --build-arg PYTHON_VERSION=3.13 \
  --build-arg BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ") \
  --build-arg GIT_COMMIT=$(git rev-parse --short HEAD) \
  -t fastapi-docker-101:latest \
  .
```

To use a secret during build (demonstrates the `--mount=type=secret` feature):

```bash
echo "my-build-secret" > secret.txt
docker build \
  --secret id=build_secret,src=secret.txt \
  -t fastapi-docker-101:latest \
  .
rm secret.txt
```

💡 **Tip:** The syntax directive at the top of the Dockerfile tells Docker to use the 1.5 parser, which enables heredocs and improved secret handling. Without it, those features won't work.

✅ **Result:** You'll see output showing each Dockerfile instruction executing and creating layers.

## Step 2: Run the Container Locally

Start the container:

```bash
docker run -d -p 8000:8000 --name fastapi-app fastapi-docker-101:latest
```

Test the API:

```bash
curl http://localhost:8000
```

Expected output:

```json
{
  "message": "Hello from Docker 101",
  "env": "docker-101",
  "build_arg": "not set"
}
```

Check the health endpoint:

```bash
curl http://localhost:8000/health
```

Expected output:

```json
{
  "status": "healthy"
}
```

View logs:

```bash
docker logs fastapi-app
```

Open a shell inside the running container:

```bash
docker exec -it fastapi-app /bin/bash
```

Stop the container:

```bash
docker stop fastapi-app
docker rm fastapi-app
```

## Understanding Docker Registries

A Docker registry is a storage and distribution system for Docker images. Instead of sharing Dockerfiles and having everyone rebuild images, you build once and push to a registry, then pull from any environment.

### Common Docker Registries

| Registry | Use Case | Notes |
|----------|----------|-------|
| **Docker Hub** | Public images, personal projects | Free tier available, rate limits apply |
| **AWS ECR** | Private enterprise images on AWS | Integrates with IAM, supports image scanning |
| **Google Artifact Registry** | GCP projects | Replaces deprecated GCR |
| **Azure Container Registry** | Azure projects | Integrated with Azure DevOps |
| **GitHub Container Registry** | Open source, GitHub Actions | Free for public images |
| **Harbor** | Self-hosted, air-gapped environments | Open source, supports vulnerability scanning |

### Repository vs Registry

- **Registry**: The service (e.g., AWS ECR in `us-west-2`)
- **Repository**: A collection of related images (e.g., `my-fastapi-app`)
- **Image**: A specific version identified by a tag (e.g., `my-fastapi-app:v1.2.3`)

Full image path: `123456789012.dkr.ecr.us-west-2.amazonaws.com/my-fastapi-app:v1.2.3`

## Step 3: Create an ECR Repository

Get your AWS account ID:

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export AWS_REGION=us-west-2
echo "Account ID: $AWS_ACCOUNT_ID"
```

Create an ECR repository:

```bash
aws ecr create-repository \
  --repository-name docker-101-fastapi \
  --region $AWS_REGION \
  --image-scanning-configuration scanOnPush=true \
  --encryption-configuration encryptionType=AES256
```

✅ **Result:** You'll receive JSON output with the repository URI.

Save the repository URI:

```bash
export ECR_REPO_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/docker-101-fastapi"
echo "ECR Repository: $ECR_REPO_URI"
```

⚠️ **Caution:** ECR charges $0.10/GB per month for storage. Enable lifecycle policies to automatically delete old images.

## Step 4: Authenticate to ECR

ECR uses temporary credentials from AWS IAM. The `get-login-password` command retrieves a token valid for 12 hours:

```bash
aws ecr get-login-password --region $AWS_REGION \
  | docker login --username AWS --password-stdin $ECR_REPO_URI
```

✅ **Result:** You'll see `Login Succeeded`.

## Step 5: Tag and Push the Image

Tag your local image for ECR:

```bash
docker tag fastapi-docker-101:latest $ECR_REPO_URI:latest
docker tag fastapi-docker-101:latest $ECR_REPO_URI:v1.0.0
```

💡 **Tip:** Use semantic versioning (`v1.0.0`) for production releases and `latest` for development. Never rely on `latest` in production deployments.

Push both tags:

```bash
docker push $ECR_REPO_URI:latest
docker push $ECR_REPO_URI:v1.0.0
```

You'll see the image layers uploading. Subsequent pushes are faster because Docker only uploads changed layers.

## Step 6: Verify the Image in ECR

List images in the repository:

```bash
aws ecr describe-images \
  --repository-name docker-101-fastapi \
  --region $AWS_REGION \
  --output table
```

Check the image scan results (ECR scans on push if enabled):

```bash
aws ecr describe-image-scan-findings \
  --repository-name docker-101-fastapi \
  --image-id imageTag=v1.0.0 \
  --region $AWS_REGION
```

Pull the image from ECR to verify:

```bash
docker pull $ECR_REPO_URI:v1.0.0
docker run --rm -d -p 8000:8000 --name fastapi-ecr $ECR_REPO_URI:v1.0.0
curl http://localhost:8000/health
docker stop fastapi-ecr
```

## Cleanup

Stop running FastAPI containers (containers started with `--rm` are automatically removed):

```bash
docker stop $(docker ps -q --filter name=fastapi)
```

Remove any remaining stopped FastAPI containers:

```bash
docker rm $(docker ps -aq --filter name=fastapi)
```

Remove local images:

```bash
docker rmi fastapi-docker-101:latest
docker rmi $ECR_REPO_URI:latest
docker rmi $ECR_REPO_URI:v1.0.0
```

Delete the ECR repository:

```bash
aws ecr delete-repository \
  --repository-name docker-101-fastapi \
  --region $AWS_REGION \
  --force
```

Clean up local files:

```bash
cd ..
rm -rf docker-101-fastapi
```

## Production Considerations

This guide covered the fundamentals, but production Docker usage requires additional steps:

**Security:**

- Never run containers as root (we used `USER appuser`)
- Scan images for vulnerabilities (ECR scanning, Trivy, Snyk)
- Use minimal base images (`slim`, `alpine`, or distroless)
- Store secrets in AWS Secrets Manager, not environment variables
- Sign container images with AWS Signer and verify with Kyverno or Ratify

**Performance:**

- Use multi-stage builds to reduce image size
- Order Dockerfile instructions from least to most frequently changed (maximize cache hits)
- Use `.dockerignore` to exclude unnecessary files from build context
- Leverage BuildKit cache mounts for package managers

**Networking:**

- Use `EXPOSE` to document ports but configure them at runtime
- Prefer host networking (`--network host`) sparingly - it breaks container isolation
- In ECS/EKS, use service discovery instead of hardcoded IPs

**IAM & Access:**

- Use IAM roles for ECR access, not long-lived credentials
- In GitHub Actions, use OIDC federation (see [Stop Using Access Keys in GitHub Actions](./stop-using-access-keys-github-actions-aws.md))
- Set ECR repository policies to restrict who can push images

**Cost:**

- Enable ECR lifecycle policies to automatically delete old images
- Use image compression and slim base images to reduce storage costs
- Monitor ECR storage usage with CloudWatch

## What's Next

You've mastered single-container workflows, but real applications need databases, message queues, reverse proxies, and multiple services working together. Starting each service with `docker run` becomes unmanageable fast.

Docker Compose solves this by defining your entire stack in a single YAML file. You declare services, their dependencies, networks, volumes, and environment variables, then start everything with one command. It's the standard tool for local development, integration testing, and small production deployments.

The next step is learning Docker Compose. You'll learn how to:

- Orchestrate multiple containers with service dependencies and health checks
- Manage persistent data with named volumes and bind mounts
- Configure environment variables and secrets across services
- Use essential commands for local development workflows

See [Host Your Own Ghost CMS Locally: Multi-Service Stack with Docker Compose](./host-ghost-cms-locally-multi-service-stack-docker-compose.md) to build a complete multi-service stack with Ghost CMS, MySQL, MailHog, and Caddy reverse proxy.

## Conclusion

You've learned the Docker fundamentals that every DevOps engineer needs:

- **Why Docker exists:** Consistency, isolation, and portability for applications
- **Core concepts:** Images are templates, containers are running instances, Dockerfiles are build instructions
- **Essential commands:** Build, run, inspect, exec, push, pull, and cleanup
- **Dockerfile anatomy:** FROM, ARG, ENV, WORKDIR, COPY, RUN, EXPOSE, USER, ENTRYPOINT, CMD
- **Container registries:** ECR for AWS environments, authenticated push/pull workflow
