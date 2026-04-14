# ==============================================================================
# Spooktacular on EC2 Mac -- Terraform Reference Module
# ==============================================================================
#
# This module provisions:
#   1. A Dedicated Host (mac2.metal) -- required for EC2 Mac instances
#   2. An EC2 Mac instance on that host, running macOS 14+
#   3. A security group allowing SSH (22) and the Spooktacular API (8484)
#   4. An IAM instance profile for SSM access (remote management)
#
# Usage:
#   cd deploy/ec2-mac/terraform
#   terraform init
#   terraform plan
#   terraform apply
#
# IMPORTANT: Dedicated Hosts have a 24-hour minimum allocation period.
# You will be billed for at least 24 hours once the host is allocated,
# even if you destroy the instance sooner.
# ==============================================================================

# ------------------------------------------------------------------------------
# Data sources
# ------------------------------------------------------------------------------

# Find the latest macOS AMI from Amazon
data "aws_ami" "macos" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = [var.macos_ami_name_filter]
  }

  filter {
    name   = "architecture"
    values = ["arm64_mac"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# Look up the VPC for the provided subnet
data "aws_subnet" "selected" {
  id = var.subnet_id
}

# Read the bootstrap script to pass as user-data
locals {
  bootstrap_script = file("${path.module}/../bootstrap.sh")
}

# ------------------------------------------------------------------------------
# Dedicated Host
# ------------------------------------------------------------------------------
#
# EC2 Mac instances MUST run on Dedicated Hosts. Each host is a physical Mac
# allocated exclusively to your account, satisfying the Apple EULA requirement
# for physical machine isolation.
#
# 24-HOUR MINIMUM: Once allocated, you are billed for at least 24 hours.
# Plan accordingly. Use Host Resource Groups (via AWS License Manager) for
# automatic allocation/release in production.

resource "aws_ec2_host" "mac" {
  instance_type     = var.instance_type
  availability_zone = data.aws_subnet.selected.availability_zone

  # auto-placement allows instances to launch on any available host you own
  # in this AZ. Set to "off" if you need to pin instances to specific hosts.
  auto_placement = "on"

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-host"
  })
}

# ------------------------------------------------------------------------------
# Security Group
# ------------------------------------------------------------------------------
#
# Allows inbound access for:
#   - SSH (port 22) for initial setup and debugging
#   - Spooktacular API (port 8484) for VM management over TLS
#
# In production, restrict the CIDR blocks to your VPN, bastion, or
# Kubernetes controller node IPs only.

resource "aws_security_group" "spooktacular" {
  name_prefix = "${var.name_prefix}-"
  description = "Spooktacular EC2 Mac -- SSH and API access"
  vpc_id      = data.aws_subnet.selected.vpc_id

  # SSH access
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  # Spooktacular API (TLS)
  ingress {
    description = "Spooktacular API (HTTPS)"
    from_port   = 8484
    to_port     = 8484
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  # Allow all outbound (needed for downloading Spooktacular, macOS IPSW, etc.)
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-sg"
  })
}

# ------------------------------------------------------------------------------
# IAM Role + Instance Profile (for SSM)
# ------------------------------------------------------------------------------
#
# Grants the instance SSM access so you can manage it via AWS Systems Manager
# instead of opening SSH to the internet. This is the AWS-recommended approach.

resource "aws_iam_role" "ec2_mac" {
  name_prefix = "${var.name_prefix}-"
  description = "EC2 Mac instance role for SSM and Spooktacular"

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

  tags = var.tags
}

# Attach the SSM managed policy for Systems Manager access
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2_mac.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_mac" {
  name_prefix = "${var.name_prefix}-"
  role        = aws_iam_role.ec2_mac.name

  tags = var.tags
}

# ------------------------------------------------------------------------------
# EC2 Mac Instance
# ------------------------------------------------------------------------------
#
# Launches on the Dedicated Host with the bootstrap script as user-data.
# The bootstrap script installs Spooktacular, generates TLS certs, creates
# a base VM, and starts the API server.

resource "aws_instance" "mac" {
  ami           = data.aws_ami.macos.id
  instance_type = var.instance_type
  host_id       = aws_ec2_host.mac.id
  key_name      = var.key_name
  subnet_id     = var.subnet_id

  vpc_security_group_ids = [aws_security_group.spooktacular.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_mac.name

  # Bootstrap script runs on first boot. It is idempotent (safe to re-run).
  user_data = base64encode(local.bootstrap_script)

  # EC2 Mac instances require a large root volume for macOS + VM storage.
  # 200GB is a reasonable starting point for 2 VMs (~64GB each + OS).
  root_block_device {
    volume_size           = var.root_volume_size_gb
    volume_type           = "gp3"
    iops                  = 6000
    throughput            = 400
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 only -- security best practice
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-instance"
    Role = "spooktacular-host"
  })
}
