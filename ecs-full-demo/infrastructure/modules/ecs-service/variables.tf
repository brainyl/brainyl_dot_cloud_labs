variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "service_name" {
  description = "Name of the service (e.g., mysql, backend, frontend)"
  type        = string
}

variable "cluster_id" {
  description = "ECS cluster ID"
  type        = string
}

variable "cluster_name" {
  description = "ECS cluster name"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of subnet IDs for the service"
  type        = list(string)
}

variable "security_group_ids" {
  description = "List of security group IDs for the service"
  type        = list(string)
}

variable "task_execution_role_arn" {
  description = "ARN of the task execution role"
  type        = string
}

variable "task_role_arn" {
  description = "ARN of the task role"
  type        = string
}

# Container configuration
variable "container_image" {
  description = "Docker image for the container"
  type        = string
}

variable "container_port" {
  description = "Port exposed by the container"
  type        = number
}

variable "cpu" {
  description = "CPU units for the task (256, 512, 1024, 2048, 4096)"
  type        = number
}

variable "memory" {
  description = "Memory for the task in MB (512, 1024, 2048, 4096, 8192)"
  type        = number
}

variable "environment_variables" {
  description = "Map of environment variables"
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "List of secrets from Secrets Manager"
  type = list(object({
    name      = string
    valueFrom = string
  }))
  default = []
}

variable "health_check" {
  description = "Container health check configuration"
  type = object({
    command     = list(string)
    interval    = number
    timeout     = number
    retries     = number
    startPeriod = number
  })
  default = null
}

# Volumes and mount points
variable "volumes" {
  description = "List of volumes for the task"
  type = list(object({
    name                     = string
    host_path                = optional(string)
    efs_volume_configuration = optional(object({
      file_system_id          = string
      transit_encryption      = string
      transit_encryption_port = number
      authorization_config = optional(object({
        iam             = string
        access_point_id = optional(string)
      }))
    }))
  }))
  default = []
}

variable "mount_points" {
  description = "List of mount points for the container"
  type = list(object({
    sourceVolume  = string
    containerPath = string
    readOnly      = bool
  }))
  default = []
}

# Service discovery
variable "enable_service_discovery" {
  description = "Enable service discovery for this service (Legacy Cloud Map)"
  type        = bool
  default     = false
}

variable "service_discovery_namespace_id" {
  description = "Service discovery namespace ID (Legacy Cloud Map)"
  type        = string
  default     = ""
}

variable "service_discovery_namespace_name" {
  description = "Service discovery namespace name (Legacy Cloud Map)"
  type        = string
  default     = ""
}

# Service Connect (Modern approach - recommended)
variable "enable_service_connect" {
  description = "Enable ECS Service Connect for this service"
  type        = bool
  default     = false
}

variable "service_connect_namespace" {
  description = "Service Connect namespace (e.g., 'simple-app-dev.local')"
  type        = string
  default     = ""
}

variable "service_connect_client_only" {
  description = "If true, service only acts as a client (doesn't expose endpoints)"
  type        = bool
  default     = false
}

variable "service_connect_app_protocol" {
  description = "Application protocol for Service Connect port mapping (http, http2, grpc). Set to null for raw TCP services like MySQL — Envoy will not apply HTTP-level protocol inspection. NOTE: this value is immutable on an existing Service Connect service; changing it requires the service to be destroyed and recreated."
  type        = string
  default     = "http"
  nullable    = true
}

# Load balancer
variable "enable_load_balancer" {
  description = "Enable load balancer for this service"
  type        = bool
  default     = false
}

variable "target_group_arn" {
  description = "Target group ARN for load balancer"
  type        = string
  default     = ""
}

# Deployment strategy
variable "deployment_maximum_percent" {
  description = "Upper limit on the number of running tasks during a deployment as a percentage of desired_count. Set to 100 for stateful single-instance services (e.g. MySQL with a host-path volume) to force stop-old-then-start-new."
  type        = number
  default     = 200
}

variable "deployment_minimum_healthy_percent" {
  description = "Lower limit on running tasks during a deployment as a percentage of desired_count. Set to 0 alongside deployment_maximum_percent=100 for stateful services that cannot run two instances simultaneously."
  type        = number
  default     = 100
}

# Scaling
variable "desired_count" {
  description = "Desired number of tasks"
  type        = number
  default     = 1
}

variable "enable_autoscaling" {
  description = "Enable auto-scaling for this service"
  type        = bool
  default     = false
}

variable "min_capacity" {
  description = "Minimum number of tasks for auto-scaling"
  type        = number
  default     = 1
}

variable "max_capacity" {
  description = "Maximum number of tasks for auto-scaling"
  type        = number
  default     = 4
}

variable "cpu_target_value" {
  description = "Target CPU utilization percentage for auto-scaling"
  type        = number
  default     = 70
}

variable "memory_target_value" {
  description = "Target memory utilization percentage for auto-scaling"
  type        = number
  default     = 80
}

# Launch type
variable "launch_type" {
  description = "Launch type for the service (FARGATE or EC2)"
  type        = string
  default     = "FARGATE"
}

variable "requires_compatibilities" {
  description = "Set of launch types required by the task"
  type        = list(string)
  default     = null
}

variable "capacity_provider_name" {
  description = "Name of the capacity provider (for EC2 launch type)"
  type        = string
  default     = ""
}

variable "placement_constraints" {
  description = "Placement constraints for the service"
  type = list(object({
    type       = string
    expression = optional(string)
  }))
  default = []
}
