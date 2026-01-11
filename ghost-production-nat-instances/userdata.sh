#!/bin/bash
set -e

PROJECT_NAME="${project_name}"
AWS_REGION="${aws_region}"
DOMAIN_NAME="${domain_name}"

apt-get update
apt-get upgrade -y

# Install AWS CLI v2
apt-get install -y unzip curl
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/awscliv2.zip /tmp/aws

apt-get install -y jq

# Fetch database connection details
DB_HOST=$(aws ssm get-parameter --name "/$PROJECT_NAME/db-host" --region $AWS_REGION --query 'Parameter.Value' --output text)
DB_NAME=$(aws ssm get-parameter --name "/$PROJECT_NAME/db-name" --region $AWS_REGION --query 'Parameter.Value' --output text)
DB_USER=$(aws ssm get-parameter --name "/$PROJECT_NAME/db-username" --region $AWS_REGION --query 'Parameter.Value' --output text)

SECRET_ARN=$(aws ssm get-parameter --name "/$PROJECT_NAME/db-password" --region $AWS_REGION --query 'Parameter.Value' --output text)
DB_PASS=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --region $AWS_REGION --query 'SecretString' --output text | jq -r '.password')

# Install Node.js 22
apt-get install -y ca-certificates curl gnupg
mkdir -p /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
NODE_MAJOR=22
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list
apt-get update
apt-get install nodejs -y

apt-get install -y mysql-client
npm install ghost-cli@latest -g

mkdir -p /var/www/ghost
chown ubuntu:ubuntu /var/www/ghost
chmod 775 /var/www/ghost

sudo -u ubuntu env DOMAIN_NAME="$DOMAIN_NAME" DB_HOST="$DB_HOST" DB_NAME="$DB_NAME" DB_USER="$DB_USER" DB_PASS="$DB_PASS" NODE_ENV="production" bash <<'EOF'
set -e
cd /var/www/ghost
export NODE_ENV="production"

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

# Test database connectivity (optional - Ghost will fail to start if DB is unreachable)
echo "Testing database connectivity..."
mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -e "SELECT 1;" 2>&1 || {
  echo "WARNING: Cannot connect to database yet. Ghost will retry when it starts."
  echo "Host: $DB_HOST"
  echo "User: $DB_USER"
  echo "Database: $DB_NAME"
}

ghost setup nginx --no-prompt
ghost start
EOF