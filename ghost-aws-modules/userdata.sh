#!/bin/bash
set -e

# Variables (will be replaced by Terraform templatefile)
PROJECT_NAME="${project_name}"
AWS_REGION="${aws_region}"
DOMAIN_NAME="${domain_name}"

# Update system packages
apt-get update
apt-get upgrade -y

# Install AWS CLI v2
apt-get install -y unzip curl
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/awscliv2.zip /tmp/aws

# Install jq for JSON parsing
apt-get install -y jq

# Fetch database connection details from SSM Parameter Store
DB_HOST=$(aws ssm get-parameter --name "/$PROJECT_NAME/db-host" --region $AWS_REGION --query 'Parameter.Value' --output text)
DB_NAME=$(aws ssm get-parameter --name "/$PROJECT_NAME/db-name" --region $AWS_REGION --query 'Parameter.Value' --output text)
DB_USER=$(aws ssm get-parameter --name "/$PROJECT_NAME/db-username" --region $AWS_REGION --query 'Parameter.Value' --output text)

# Fetch password from Secrets Manager (RDS managed password)
SECRET_ARN=$(aws ssm get-parameter --name "/$PROJECT_NAME/db-password" --region $AWS_REGION --query 'Parameter.Value' --output text)
if [[ $SECRET_ARN == arn:aws:secretsmanager:* ]]; then
  echo "Fetching password from Secrets Manager (RDS managed password)"
  echo "Secret ARN: $SECRET_ARN"
  DB_PASS=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --region $AWS_REGION --query 'SecretString' --output text | jq -r '.password')
  echo "Successfully retrieved password from Secrets Manager"
else
  echo "Using password directly from SSM Parameter Store"
  DB_PASS="$SECRET_ARN"
fi

# Install Node.js 22
apt-get install -y ca-certificates curl gnupg
mkdir -p /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
NODE_MAJOR=22
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list
apt-get update
apt-get install nodejs -y

# Install MySQL client
apt-get install -y mysql-client

# Install Ghost-CLI
npm install ghost-cli@latest -g

# Create Ghost directory
mkdir -p /var/www/ghost
chown ubuntu:ubuntu /var/www/ghost
chmod 775 /var/www/ghost

# Install Ghost as ubuntu user
# Pass variables as environment variables to the sudo command
sudo -u ubuntu env DOMAIN_NAME="$DOMAIN_NAME" DB_HOST="$DB_HOST" DB_NAME="$DB_NAME" DB_USER="$DB_USER" DB_PASS="$DB_PASS" NODE_ENV="production" bash <<'EOF'
set -e

cd /var/www/ghost

# Set URL and environment variables for Ghost-CLI (must be set before any ghost commands)
export NODE_ENV="production"

# Use ghost install with database flags for non-interactive setup
# This properly initializes the instance and creates systemd service with correct name
echo "Installing Ghost with non-interactive setup..."
ghost install \
  --url "https://$DOMAIN_NAME" \
  --db mysql \
  --dbhost "$DB_HOST" \
  --dbuser "$DB_USER" \
  --dbpass "$DB_PASS" \
  --dbname "$DB_NAME" \
  --no-prompt \
  --no-stack \
  --no-setup-nginx \
  --no-setup-ssl \
  --no-setup-mysql \
  --process systemd \
  --no-start

# Verify the config file was created
if [ ! -f config.production.json ]; then
  echo "ERROR: config.production.json was not created by ghost install"
  exit 1
fi

# Update config file to ensure correct database credentials
# Ghost-CLI might have created a 'ghostadmin' user, but we need to use the provided credentials
echo "Updating config with correct database credentials..."
cat > config.production.json <<CONFIG
{
  "url": "https://$DOMAIN_NAME",
  "server": {
    "port": 2368,
    "host": "0.0.0.0"
  },
  "database": {
    "client": "mysql",
    "connection": {
      "host": "$DB_HOST",
      "user": "$DB_USER",
      "password": "$DB_PASS",
      "database": "$DB_NAME",
      "charset": "utf8mb4"
    }
  },
  "mail": {
    "transport": "Direct"
  },
  "logging": {
    "transports": ["stdout"]
  },
  "process": "systemd",
  "paths": {
    "contentPath": "/var/www/ghost/content"
  }
}
CONFIG

# Debug: Show what was created
echo "=== Ghost installation complete ==="
echo "Config file contents:"
cat config.production.json
echo "================================="

# Test database connectivity with the provided credentials
echo "Testing database connectivity..."
mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -e "SELECT 1;" 2>&1 || {
  echo "ERROR: Cannot connect to database with provided credentials"
  echo "Host: $DB_HOST"
  echo "User: $DB_USER"
  echo "Database: $DB_NAME"
  exit 1
}
echo "Database connectivity test passed!"

# Verify systemd service was created with correct name
DOMAIN_ONLY=$(echo "$DOMAIN_NAME" | sed 's|https\?://||' | sed 's|/.*||')
EXPECTED_SERVICE="ghost_$(echo "$DOMAIN_ONLY" | tr '.' '-')"
echo "Expected service name: $${EXPECTED_SERVICE}"

if [ -f "/lib/systemd/system/$${EXPECTED_SERVICE}.service" ]; then
  echo "SUCCESS: Systemd service $${EXPECTED_SERVICE}.service was created"
else
  echo "WARNING: Expected systemd service $${EXPECTED_SERVICE}.service not found"
  echo "Checking for any ghost systemd services:"
  ls -la /lib/systemd/system/ghost_* 2>/dev/null || echo "No ghost services found"
fi

# Set up NGINX (skip SSL since we're using ALB with ACM)
echo "Setting up NGINX..."
ghost setup nginx --no-prompt

# Start Ghost
echo "Starting Ghost..."
ghost start
EOF

echo "Ghost installation complete!"

