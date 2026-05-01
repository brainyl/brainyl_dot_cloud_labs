#!/bin/bash
set -e

# Configure ECS agent
echo "ECS_CLUSTER=${cluster_name}" >> /etc/ecs/ecs.config
echo "ECS_ENABLE_TASK_IAM_ROLE=true" >> /etc/ecs/ecs.config
echo "ECS_ENABLE_TASK_IAM_ROLE_NETWORK_HOST=true" >> /etc/ecs/ecs.config

# Format and mount EBS volume for MySQL if not already formatted
if ! blkid /dev/sdf; then
  mkfs.ext4 /dev/sdf
fi

mkdir -p /mnt/mysql-data
mount /dev/sdf /mnt/mysql-data
echo "/dev/sdf /mnt/mysql-data ext4 defaults,nofail 0 2" >> /etc/fstab

# Set permissions for MySQL
chown -R 999:999 /mnt/mysql-data
chmod 755 /mnt/mysql-data
