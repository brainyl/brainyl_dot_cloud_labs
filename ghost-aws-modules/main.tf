################################################################################
# VPC Module
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "${var.project_name}-vpc"
  cidr = var.vpc_cidr

  azs              = var.availability_zones
  public_subnets   = [for k, v in var.availability_zones : cidrsubnet(var.vpc_cidr, 4, k)]
  private_subnets  = [for k, v in var.availability_zones : cidrsubnet(var.vpc_cidr, 4, k + length(var.availability_zones))]
  database_subnets = [for k, v in var.availability_zones : cidrsubnet(var.vpc_cidr, 4, k + (2 * length(var.availability_zones)))]

  enable_nat_gateway = true
  single_nat_gateway = true # Cost optimization: use one NAT GW
  enable_dns_hostnames = true
  enable_dns_support   = true

  create_database_subnet_group = true

  tags = {
    Project = var.project_name
  }
}

################################################################################
# Security Groups
################################################################################

module "alb_security_group" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = "${var.project_name}-alb-sg"
  description = "Security group for ALB"
  vpc_id      = module.vpc.vpc_id

  ingress_with_cidr_blocks = [
    {
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = "0.0.0.0/0"
      description = "Allow HTTP from anywhere"
    },
    {
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = "0.0.0.0/0"
      description = "Allow HTTPS from anywhere"
    }
  ]

  egress_with_cidr_blocks = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = "0.0.0.0/0"
      description = "Allow all outbound"
    }
  ]

  tags = {
    Project = var.project_name
  }
}

module "ec2_security_group" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = "${var.project_name}-ec2-sg"
  description = "Security group for Ghost EC2 instances"
  vpc_id      = module.vpc.vpc_id

  computed_ingress_with_source_security_group_id = [
    {
      from_port                = 2368
      to_port                  = 2368
      protocol                 = "tcp"
      source_security_group_id = module.alb_security_group.security_group_id
      description              = "Allow Ghost traffic from ALB"
    }
  ]

  number_of_computed_ingress_with_source_security_group_id = 1

  egress_with_cidr_blocks = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = "0.0.0.0/0"
      description = "Allow all outbound"
    }
  ]

  tags = {
    Project = var.project_name
  }
}

module "aurora_security_group" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = "${var.project_name}-aurora-sg"
  description = "Security group for Aurora"
  vpc_id      = module.vpc.vpc_id

  computed_ingress_with_source_security_group_id = [
    {
      from_port                = 3306
      to_port                  = 3306
      protocol                 = "tcp"
      source_security_group_id = module.ec2_security_group.security_group_id
      description              = "Allow MySQL from EC2"
    }
  ]

  number_of_computed_ingress_with_source_security_group_id = 1

  egress_with_cidr_blocks = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = "0.0.0.0/0"
      description = "Allow all outbound"
    }
  ]

  tags = {
    Project = var.project_name
  }
}

################################################################################
# Aurora Serverless v2
################################################################################

module "aurora" {
  source  = "terraform-aws-modules/rds-aurora/aws"
  version = "~> 9.0"

  name           = "${var.project_name}-cluster"
  engine         = "aurora-mysql"
  engine_mode    = "provisioned"
  engine_version = "8.0.mysql_aurora.3.10.0"

  master_username              = var.db_master_username
  manage_master_user_password  = true
  database_name                = var.db_name

  vpc_id                 = module.vpc.vpc_id
  db_subnet_group_name   = module.vpc.database_subnet_group_name
  create_db_subnet_group = false

  vpc_security_group_ids = [module.aurora_security_group.security_group_id]

  skip_final_snapshot = true

  serverlessv2_scaling_configuration = {
    min_capacity = 0.0
    max_capacity = 1
  }

  instance_class = "db.serverless"
  instances = {
    one = {}
  }

  tags = {
    Project = var.project_name
  }
}

################################################################################
# SSM Parameters for Database Connection
################################################################################

resource "aws_ssm_parameter" "db_host" {
  name  = "/${var.project_name}/db-host"
  type  = "String"
  value = module.aurora.cluster_endpoint

  tags = {
    Project = var.project_name
  }
}

resource "aws_ssm_parameter" "db_name" {
  name  = "/${var.project_name}/db-name"
  type  = "String"
  value = var.db_name

  tags = {
    Project = var.project_name
  }
}

resource "aws_ssm_parameter" "db_username" {
  name  = "/${var.project_name}/db-username"
  type  = "String"
  value = var.db_master_username

  tags = {
    Project = var.project_name
  }
}

resource "aws_ssm_parameter" "db_password" {
  name  = "/${var.project_name}/db-password"
  type  = "String"
  value = module.aurora.cluster_master_user_secret[0].secret_arn

  tags = {
    Project = var.project_name
  }
}

################################################################################
# IAM Role for EC2 Instances
################################################################################

resource "aws_iam_role" "ec2_role" {
  name = "${var.project_name}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Project = var.project_name
  }
}

resource "aws_iam_role_policy" "ec2_ssm_policy" {
  name = "${var.project_name}-ec2-ssm-policy"
  role = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/${var.project_name}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:*:secret:rds!cluster-*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_ssm_managed" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

################################################################################
# Application Load Balancer
################################################################################

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 10.0"

  name = "${var.project_name}-alb"

  load_balancer_type = "application"
  vpc_id             = module.vpc.vpc_id
  subnets            = module.vpc.public_subnets
  security_groups    = [module.alb_security_group.security_group_id]

  enable_deletion_protection = false

  listeners = {
    http = {
      port     = 80
      protocol = "HTTP"

      redirect = {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
    https = {
      port            = 443
      protocol        = "HTTPS"
      certificate_arn = local.acm_certificate_arn_alb

      forward = {
        target_group_key = "ghost"
      }
    }
  }

  target_groups = {
    ghost = {
      name                 = "${var.project_name}-tg"
      protocol             = "HTTP"
      port                 = 2368
      target_type          = "instance"
      deregistration_delay = 10
      create_attachment    = false # ASG handles attachments via traffic_source_attachments

      health_check = {
        enabled             = true
        healthy_threshold   = 2
        unhealthy_threshold = 3
        timeout             = 10
        interval            = 30
        path                = "/"
        matcher             = "200,301,302"
      }
    }
  }

  tags = {
    Project = var.project_name
  }
}

################################################################################
# Auto Scaling Group
################################################################################

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

module "asg" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "~> 9.0"

  name = "${var.project_name}-asg"

  min_size         = var.asg_min_size
  max_size         = var.asg_max_size
  desired_capacity = var.asg_desired_capacity

  vpc_zone_identifier = module.vpc.private_subnets
  traffic_source_attachments = {
    ghost = {
      traffic_source_identifier = module.alb.target_groups["ghost"].arn
      traffic_source_type       = "elbv2"
    }
  }
  health_check_type   = "ELB"
  health_check_grace_period = 300

  image_id      = data.aws_ami.ubuntu.id
  instance_type = var.ec2_instance_type

  iam_instance_profile_arn = aws_iam_instance_profile.ec2_profile.arn
  security_groups          = [module.ec2_security_group.security_group_id]

  user_data = base64encode(templatefile("${path.module}/userdata.sh", {
    project_name = var.project_name
    aws_region   = var.aws_region
    domain_name  = var.domain_name
  }))

  create_launch_template = true
  launch_template_name   = "${var.project_name}-lt"

  tags = {
    Project = var.project_name
  }
}

################################################################################
# Route53 Hosted Zone Lookup
################################################################################

# Try to find Route53 hosted zone for the domain (exact match)
# If you have a parent domain zone (e.g., brainyl.cloud) for a subdomain (lab.brainyl.cloud),
# provide route53_zone_id explicitly
data "aws_route53_zone" "main" {
  count        = var.route53_zone_id == null ? 1 : 0
  name         = var.domain_name
  private_zone = false
}

locals {
  route53_zone_id = coalesce(
    var.route53_zone_id,
    try(data.aws_route53_zone.main[0].zone_id, null)
  )
  has_route53_zone = local.route53_zone_id != null
}

################################################################################
# ACM Certificates
################################################################################

# ACM Certificate for CloudFront (must be in us-east-1)
module "acm_cloudfront" {
  source  = "terraform-aws-modules/acm/aws"
  version = "~> 5.0"

  providers = {
    aws = aws.us_east_1
  }

  domain_name = var.domain_name
  zone_id     = local.route53_zone_id

  validation_method      = "DNS"
  create_route53_records = local.has_route53_zone # Automatically create DNS records if Route53 zone found
  wait_for_validation    = local.has_route53_zone # Wait for validation if Route53 zone found

  tags = {
    Project = var.project_name
    Purpose = "CloudFront"
  }
}

# ACM Certificate for ALB (must be in us-west-2)
module "acm_alb" {
  source  = "terraform-aws-modules/acm/aws"
  version = "~> 5.0"

  domain_name = var.domain_name
  zone_id     = local.route53_zone_id

  validation_method      = "DNS"
  create_route53_records = local.has_route53_zone # Automatically create DNS records if Route53 zone found
  wait_for_validation    = local.has_route53_zone # Wait for validation if Route53 zone found

  tags = {
    Project = var.project_name
    Purpose = "ALB"
  }
}

# Use provided certificate ARN or the one created above
# IMPORTANT: Certificate must be VALIDATED before CloudFront can use it
locals {
  acm_certificate_arn_cloudfront = var.acm_certificate_arn != null ? var.acm_certificate_arn : module.acm_cloudfront.acm_certificate_arn
  acm_certificate_arn_alb        = module.acm_alb.acm_certificate_arn
}

################################################################################
# CloudFront Cache Policies
################################################################################

# Custom cache policy for static assets with long TTL (1 year)
resource "aws_cloudfront_cache_policy" "static_assets_cache" {
  name    = "${var.project_name}-static-assets-cache-policy"
  comment = "Cache policy for static assets with 1 year TTL"

  min_ttl     = 86400      # 1 day minimum
  default_ttl = 31536000   # 1 year default
  max_ttl     = 31536000   # 1 year maximum

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }

    headers_config {
      header_behavior = "none"
    }

    query_strings_config {
      query_string_behavior = "none"
    }

    enable_accept_encoding_brotli = true
    enable_accept_encoding_gzip   = true
  }
}

################################################################################
# CloudFront Origin Request Policies
################################################################################

# Policy for dynamic content (Ghost admin) - forwards all headers/cookies
resource "aws_cloudfront_origin_request_policy" "alb_origin_policy" {
  name    = "${var.project_name}-alb-origin-request-policy"
  comment = "Origin request policy for ALB (Ghost) origin - forwards all viewer headers and cookies"

  cookies_config {
    cookie_behavior = "all"
  }

  headers_config {
    header_behavior = "allViewer"
  }

  query_strings_config {
    query_string_behavior = "all"
  }
}

# Policy for static assets - only forwards Host header
resource "aws_cloudfront_origin_request_policy" "static_assets_policy" {
  name    = "${var.project_name}-static-assets-origin-request-policy"
  comment = "Origin request policy for static assets - forwards only Host header"

  cookies_config {
    cookie_behavior = "none"
  }

  headers_config {
    header_behavior = "whitelist"
    headers {
      items = ["Host"]
    }
  }

  query_strings_config {
    query_string_behavior = "none"
  }
}

################################################################################
# CloudFront Distribution
################################################################################

module "cloudfront" {
  source  = "terraform-aws-modules/cloudfront/aws"
  version = "~> 3.0"

  aliases = [var.domain_name]

  comment             = "Ghost blog distribution"
  enabled             = true
  is_ipv6_enabled     = true
  price_class         = "PriceClass_100"
  retain_on_delete    = false
  wait_for_deployment = false

  origin = {
    alb = {
      domain_name = module.alb.dns_name
      custom_origin_config = {
        http_port              = 80
        https_port             = 443
        origin_protocol_policy = "https-only"
        origin_ssl_protocols   = ["TLSv1.2"]
      }
    }
  }

  default_cache_behavior = {
    target_origin_id       = "alb"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods  = ["GET", "HEAD"]
    compress        = true

    use_forwarded_values          = false
    cache_policy_name             = "Managed-CachingDisabled"
    origin_request_policy_id      = aws_cloudfront_origin_request_policy.alb_origin_policy.id
  }

  ordered_cache_behavior = [
    {
      path_pattern           = "/assets/*"
      target_origin_id       = "alb"
      viewer_protocol_policy = "redirect-to-https"

      allowed_methods = ["GET", "HEAD", "OPTIONS"]
      cached_methods  = ["GET", "HEAD"]
      compress        = true

      use_forwarded_values        = false
      cache_policy_id             = aws_cloudfront_cache_policy.static_assets_cache.id
      origin_request_policy_id    = aws_cloudfront_origin_request_policy.static_assets_policy.id
    },
    {
      path_pattern           = "/content/images/*"
      target_origin_id       = "alb"
      viewer_protocol_policy = "redirect-to-https"

      allowed_methods = ["GET", "HEAD", "OPTIONS"]
      cached_methods  = ["GET", "HEAD"]
      compress        = true

      use_forwarded_values        = false
      cache_policy_id             = aws_cloudfront_cache_policy.static_assets_cache.id
      origin_request_policy_id    = aws_cloudfront_origin_request_policy.static_assets_policy.id
    },
    {
      path_pattern           = "/media/*"
      target_origin_id       = "alb"
      viewer_protocol_policy = "redirect-to-https"

      allowed_methods = ["GET", "HEAD", "OPTIONS"]
      cached_methods  = ["GET", "HEAD"]
      compress        = true

      use_forwarded_values        = false
      cache_policy_id             = aws_cloudfront_cache_policy.static_assets_cache.id
      origin_request_policy_id    = aws_cloudfront_origin_request_policy.static_assets_policy.id
    },
    {
      path_pattern           = "/ghost/*"
      target_origin_id       = "alb"
      viewer_protocol_policy = "redirect-to-https"

      allowed_methods = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
      cached_methods  = ["GET", "HEAD"]

      use_forwarded_values          = false
      cache_policy_name             = "Managed-CachingDisabled"
      origin_request_policy_id      = aws_cloudfront_origin_request_policy.alb_origin_policy.id
    },
    {
      path_pattern           = "/ghost/api/*"
      target_origin_id       = "alb"
      viewer_protocol_policy = "redirect-to-https"

      allowed_methods = ["GET", "HEAD", "OPTIONS"]
      cached_methods  = ["GET", "HEAD"]

      use_forwarded_values          = false
      cache_policy_name             = "Managed-CachingDisabled"
      origin_request_policy_id      = aws_cloudfront_origin_request_policy.alb_origin_policy.id
    }
  ]

  viewer_certificate = {
    acm_certificate_arn      = local.acm_certificate_arn_cloudfront
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = {
    Project = var.project_name
  }
}

################################################################################
# Route53 Record for CloudFront
################################################################################

resource "aws_route53_record" "cloudfront" {
  count   = local.has_route53_zone ? 1 : 0
  zone_id = local.route53_zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = module.cloudfront.cloudfront_distribution_domain_name
    zone_id                = module.cloudfront.cloudfront_distribution_hosted_zone_id
    evaluate_target_health = false
  }
}

