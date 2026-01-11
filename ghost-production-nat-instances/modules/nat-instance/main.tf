terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.0"
    }
  }
}

locals {
  create_instances = var.create && var.nat_count > 0
}

################################################################################
# Security Group
################################################################################

resource "aws_security_group" "this" {
  count       = var.create ? 1 : 0
  name        = "${var.name}-nat-instance-sg"
  description = "Security group for NAT instances"
  vpc_id      = var.vpc_id

  tags = merge({
    Name = "${var.name}-nat-instance-sg"
  }, var.tags)
}

resource "aws_security_group_rule" "ingress" {
  for_each = var.create ? toset(var.allowed_inbound_cidrs) : toset([])

  type              = "ingress"
  security_group_id = aws_security_group.this[0].id
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = [each.value]
  description       = "Allow all traffic from ${each.value}"
}

resource "aws_security_group_rule" "egress_ipv4" {
  count = var.create ? 1 : 0

  type              = "egress"
  security_group_id = aws_security_group.this[count.index].id
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Allow all outbound IPv4 traffic"
}

resource "aws_security_group_rule" "egress_ipv6" {
  count = var.create ? 1 : 0

  type              = "egress"
  security_group_id = aws_security_group.this[count.index].id
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  ipv6_cidr_blocks  = ["::/0"]
  description       = "Allow all outbound IPv6 traffic"
}

################################################################################
# NAT Instances
################################################################################

resource "aws_instance" "this" {
  count = local.create_instances ? var.nat_count : 0

  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = element(var.public_subnet_ids, var.single_nat_gateway ? 0 : count.index)
  associate_public_ip_address = true
  source_dest_check           = false  # CRITICAL: Must be false for NAT functionality
  vpc_security_group_ids      = aws_security_group.this[*].id

  tags = merge({
    Name = var.single_nat_gateway ? "${var.name}-nat-instance" : format(
      "%s-nat-instance-%s",
      var.name,
      element(var.azs, var.single_nat_gateway ? 0 : count.index)
    )
  }, var.tags)

  lifecycle {
    create_before_destroy = true
  }
}

################################################################################
# Elastic IPs
################################################################################

resource "aws_eip" "this" {
  count = local.create_instances ? var.nat_count : 0

  domain   = "vpc"
  instance = element(aws_instance.this[*].id, count.index)

  tags = merge({
    Name = var.single_nat_gateway ? "${var.name}-nat-instance-eip" : format(
      "%s-nat-instance-eip-%s",
      var.name,
      element(var.azs, var.single_nat_gateway ? 0 : count.index)
    )
  }, var.tags)

  depends_on = [aws_instance.this]
}